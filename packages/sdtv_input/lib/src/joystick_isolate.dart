import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'linux_joystick.dart';

/// Joystick pump that runs in a **background isolate**.
///
/// Opens **all** `/dev/input/js*` devices and **re-scans** periodically so a
/// pad turned on after dock (Xbox) works without restarting the app.
///
/// media_kit / heavy UI work can starve pad reads on the UI isolate; the
/// isolate only sends edge *indices* to the main isolate.
class JoystickIsolate {
  JoystickIsolate();

  Isolate? _isolate;
  ReceivePort? _recv;
  SendPort? _toWorker;
  StreamController<GamepadEdge>? _controller;
  bool _started = false;

  Stream<GamepadEdge> get events {
    _controller ??= StreamController<GamepadEdge>.broadcast();
    return _controller!.stream;
  }

  bool get isRunning => _started && _isolate != null;

  /// Paths currently open in the worker (best-effort from log messages).
  String openPathsLabel = '';

  Future<bool> start() async {
    if (_started) return isRunning;
    _started = true;
    _controller ??= StreamController<GamepadEdge>.broadcast();

    final ready = Completer<SendPort>();
    _recv = ReceivePort();
    _recv!.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is int) {
        if (message >= 0 && message < GamepadEdge.values.length) {
          _controller?.add(GamepadEdge.values[message]);
        }
        return;
      }
      if (message is String) {
        if (message.startsWith('open ')) {
          final path = message.substring(5);
          if (openPathsLabel.isEmpty) {
            openPathsLabel = path;
          } else if (!openPathsLabel.contains(path)) {
            openPathsLabel = '$openPathsLabel,$path';
          }
        } else if (message.startsWith('paths ')) {
          openPathsLabel = message.substring(6);
        } else if (message.startsWith('close ')) {
          final path = message.substring(6);
          openPathsLabel = openPathsLabel
              .split(',')
              .where((p) => p.isNotEmpty && p != path)
              .join(',');
        }
        debugPrint('sdtv_input: isolate: $message');
      }
    });

    try {
      _isolate = await Isolate.spawn(
        _joystickIsolateMain,
        _recv!.sendPort,
        debugName: 'sdtv_joystick',
      );
      _toWorker = await ready.future.timeout(const Duration(seconds: 3));
      debugPrint('sdtv_input: joystick isolate started');
      return true;
    } catch (e, st) {
      debugPrint('sdtv_input: joystick isolate failed: $e\n$st');
      await stop();
      return false;
    }
  }

  /// Ask the worker to re-list `/dev/input/js*` (dock / pad power-on).
  void requestRescan() {
    try {
      _toWorker?.send('rescan');
    } catch (_) {}
  }

  Future<void> stop() async {
    _started = false;
    try {
      _toWorker?.send('stop');
    } catch (_) {}
    _toWorker = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _recv?.close();
    _recv = null;
    openPathsLabel = '';
  }
}

/// Top-level isolate entry (must be free function / static).
void _joystickIsolateMain(SendPort mainPort) {
  final cmd = ReceivePort();
  mainPort.send(cmd.sendPort);

  var running = true;
  final openFiles = <String, RandomAccessFile>{};
  final pumping = <String>{};

  // Mirror of LinuxJoystickReader mapping — keep in sync.
  GamepadEdge? mapButton(int number) {
    switch (number) {
      case 0:
        return GamepadEdge.confirm;
      case 1:
        return GamepadEdge.back;
      case 2:
        return GamepadEdge.mute;
      case 3:
        return GamepadEdge.favorite;
      case 4:
        return GamepadEdge.pageUp;
      case 5:
        return GamepadEdge.pageDown;
      case 6:
      case 7:
      case 8:
      case 9:
      case 10:
      case 11:
        return GamepadEdge.menu;
      default:
        return null;
    }
  }

  const stickDz = 22000;
  const hatDz = 16000;
  // Per-device state so two pads don't fight axis sign maps.
  final axisSignByDev = <String, Map<int, int>>{};
  final buttonsDownByDev = <String, Set<int>>{};
  GamepadEdge? heldDir;
  Timer? repeatTimer;

  void emit(GamepadEdge e) => mainPort.send(e.index);

  void clearHold() {
    heldDir = null;
    repeatTimer?.cancel();
    repeatTimer = null;
  }

  int signFor(int value, {required bool stick}) {
    final dz = stick ? stickDz : hatDz;
    if (value > dz) return 1;
    if (value < -dz) return -1;
    return 0;
  }

  void setHeld(GamepadEdge dir, {required bool allowRepeat}) {
    if (heldDir == dir) return;
    heldDir = dir;
    emit(dir);
    repeatTimer?.cancel();
    repeatTimer = null;
    if (!allowRepeat) return;
    repeatTimer = Timer(const Duration(milliseconds: 400), () {
      repeatTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (heldDir != null) emit(heldDir!);
      });
    });
  }

  void handleFrame(String path, Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final value = data.getInt16(4, Endian.little);
    final type = data.getUint8(6);
    final number = data.getUint8(7);
    const jsEventButton = 0x01;
    const jsEventAxis = 0x02;
    const jsEventInit = 0x80;
    final kind = type & ~jsEventInit;
    final isInit = (type & jsEventInit) != 0;

    final buttonsDown = buttonsDownByDev.putIfAbsent(path, () => <int>{});
    final axisSign = axisSignByDev.putIfAbsent(path, () => <int, int>{});

    if (kind == jsEventButton) {
      final pressed = value != 0;
      if (pressed) {
        if (buttonsDown.add(number) && !isInit) {
          clearHold();
          final edge = mapButton(number);
          if (edge != null) emit(edge);
        }
      } else {
        buttonsDown.remove(number);
      }
      return;
    }

    if (kind == jsEventAxis) {
      final isStick = number == 0 || number == 1;
      final isHat = number == 6 || number == 7;
      if (!isStick && !isHat) return;
      final sign = signFor(value, stick: isStick);
      final prev = axisSign[number] ?? 0;
      if (sign == prev) return;
      axisSign[number] = sign;
      if (isInit) return;

      if (number == 0 || number == 6) {
        if (sign < 0) {
          setHeld(GamepadEdge.left, allowRepeat: isHat);
        } else if (sign > 0) {
          setHeld(GamepadEdge.right, allowRepeat: isHat);
        } else if (heldDir == GamepadEdge.left || heldDir == GamepadEdge.right) {
          clearHold();
        }
      } else if (number == 1 || number == 7) {
        if (sign < 0) {
          setHeld(GamepadEdge.up, allowRepeat: isHat);
        } else if (sign > 0) {
          setHeld(GamepadEdge.down, allowRepeat: isHat);
        } else if (heldDir == GamepadEdge.up || heldDir == GamepadEdge.down) {
          clearHold();
        }
      }
    }
  }

  Future<void> closePath(String path) async {
    pumping.remove(path);
    final f = openFiles.remove(path);
    axisSignByDev.remove(path);
    buttonsDownByDev.remove(path);
    try {
      await f?.close();
    } catch (_) {}
    mainPort.send('close $path');
  }

  Future<void> pumpOne(String path) async {
    if (!running || pumping.contains(path)) return;
    pumping.add(path);
    final file = openFiles[path];
    if (file == null) {
      pumping.remove(path);
      return;
    }
    try {
      while (running && openFiles.containsKey(path)) {
        final bytes = await file.read(8);
        if (!running || !openFiles.containsKey(path)) break;
        if (bytes.length == 8) {
          handleFrame(path, Uint8List.fromList(bytes));
        } else if (bytes.isEmpty) {
          // Unplug / EOF
          break;
        }
      }
    } catch (_) {
      // device gone
    }
    await closePath(path);
  }

  Future<void> rescan() async {
    if (!running) return;
    final paths = LinuxJoystickReader.listDevicePaths();
    for (final path in paths) {
      if (openFiles.containsKey(path)) continue;
      try {
        final f = await File(path).open(mode: FileMode.read);
        openFiles[path] = f;
        mainPort.send('open $path');
        // Fire-and-forget pump per device.
        unawaited(pumpOne(path));
      } catch (_) {
        // busy / permission / race with udev
      }
    }
    // Drop stale paths that vanished without EOF (rare).
    final live = paths.toSet();
    for (final path in openFiles.keys.toList()) {
      if (!live.contains(path)) {
        unawaited(closePath(path));
      }
    }
    final label = openFiles.keys.toList()..sort();
    mainPort.send(
      label.isEmpty ? 'paths (none)' : 'paths ${label.join(',')}',
    );
  }

  cmd.listen((message) {
    if (message == 'stop') {
      running = false;
      clearHold();
      for (final path in openFiles.keys.toList()) {
        unawaited(closePath(path));
      }
      cmd.close();
    } else if (message == 'rescan') {
      unawaited(rescan());
    }
  });

  // Initial open + periodic hotplug (Xbox after dock, new pad, etc.).
  unawaited(rescan());
  Timer.periodic(const Duration(seconds: 2), (_) {
    if (running) unawaited(rescan());
  });
}
