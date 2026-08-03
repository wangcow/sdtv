import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'linux_joystick.dart';

/// Joystick pump that runs in a **background isolate**.
///
/// media_kit video saturates the UI isolate once frames start; async reads
/// scheduled on the UI isolate then deliver B/A/D-pad seconds late or drop.
/// The isolate only sends edge *indices* to the main isolate.
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
  }
}

/// Top-level isolate entry (must be free function / static).
void _joystickIsolateMain(SendPort mainPort) {
  final cmd = ReceivePort();
  mainPort.send(cmd.sendPort);

  RandomAccessFile? file;
  var running = true;

  // Mirror of LinuxJoystickReader mapping — keep in sync.
  GamepadEdge? mapButton(int number) {
    switch (number) {
      case 0:
        return GamepadEdge.confirm;
      case 1:
        return GamepadEdge.back;
      case 3:
        return GamepadEdge.menu;
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
  final axisSign = <int, int>{};
  final buttonsDown = <int>{};
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

  void handleFrame(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final value = data.getInt16(4, Endian.little);
    final type = data.getUint8(6);
    final number = data.getUint8(7);
    const jsEventButton = 0x01;
    const jsEventAxis = 0x02;
    const jsEventInit = 0x80;
    final kind = type & ~jsEventInit;
    final isInit = (type & jsEventInit) != 0;

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

  Future<void> openAndPump() async {
    for (var i = 0; i < 4; i++) {
      final path = '/dev/input/js$i';
      try {
        file = await File(path).open(mode: FileMode.read);
        mainPort.send('open $path');
        break;
      } catch (_) {
        file = null;
      }
    }
    if (file == null) {
      mainPort.send('no joystick');
      return;
    }

    while (running) {
      try {
        final bytes = await file!.read(8);
        if (!running) break;
        if (bytes.length == 8) {
          handleFrame(Uint8List.fromList(bytes));
        } else if (bytes.isEmpty) {
          break;
        }
      } catch (_) {
        break;
      }
    }
    try {
      await file?.close();
    } catch (_) {}
  }

  cmd.listen((message) {
    if (message == 'stop') {
      running = false;
      clearHold();
      cmd.close();
    }
  });

  // Blocking pump in isolate event loop.
  openAndPump();
}
