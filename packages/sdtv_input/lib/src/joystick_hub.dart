import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'joystick_isolate.dart';
import 'linux_joystick.dart';

/// Process-wide joystick owner. Prefers a **background isolate** so media_kit
/// video frames cannot starve pad reads on the UI isolate.
///
/// Opens every `/dev/input/js*` and **re-scans every ~2s** so a controller
/// powered on after docking (e.g. Xbox) is picked up without restarting sdtv.
class SdtvJoystickHub {
  SdtvJoystickHub._();
  static final SdtvJoystickHub instance = SdtvJoystickHub._();

  final _listeners = <void Function(GamepadEdge)>[];
  final _iso = JoystickIsolate();
  StreamSubscription<GamepadEdge>? _sub;
  final List<LinuxJoystickReader> _fallbackReaders = [];
  final List<StreamSubscription<GamepadEdge>> _fallbackSubs = [];
  Timer? _fallbackHotplug;
  Future<void>? _opening;
  Future<void>? _closing;

  bool get isOpen =>
      _iso.isRunning || _fallbackReaders.any((r) => r.isOpen);

  int get listenerCount => _listeners.length;

  String? get openPath {
    if (_iso.isRunning) {
      final p = _iso.openPathsLabel;
      return p.isEmpty ? 'isolate' : p;
    }
    if (_fallbackReaders.isEmpty) return null;
    return _fallbackReaders
        .map((r) => r.openPath)
        .whereType<String>()
        .join(',');
  }

  Future<void> acquire(void Function(GamepadEdge) onEdge) async {
    _listeners.remove(onEdge);
    _listeners.add(onEdge);
    await _ensureOpen();
  }

  Future<void> _ensureOpen() async {
    final closing = _closing;
    if (closing != null) await closing;

    if (isOpen) {
      // Already pumping — still nudge a rescan (new pad may have appeared).
      rescan();
      return;
    }
    if (_opening != null) {
      await _opening;
      return;
    }
    if (_listeners.isEmpty) return;

    _opening = _open();
    try {
      await _opening;
    } finally {
      _opening = null;
    }
  }

  Future<void> _open() async {
    final ok = await _iso.start();
    if (ok) {
      await _sub?.cancel();
      _sub = _iso.events.listen(_deliver);
      return;
    }

    await _openFallbackAll();
    _fallbackHotplug?.cancel();
    _fallbackHotplug = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_hotplugFallback());
    });
  }

  Future<void> _openFallbackAll() async {
    final paths = LinuxJoystickReader.listDevicePaths();
    final already = _fallbackReaders
        .map((r) => r.openPath)
        .whereType<String>()
        .toSet();
    for (final path in paths) {
      if (already.contains(path)) continue;
      final reader = LinuxJoystickReader(devicePath: path);
      final opened = await reader.open();
      if (opened) {
        _fallbackReaders.add(reader);
        debugPrint('sdtv_input: hub fallback open $path');
        _fallbackSubs.add(reader.events.listen(_deliver));
      } else {
        await reader.dispose();
      }
    }
    if (_fallbackReaders.isEmpty) {
      debugPrint('sdtv_input: hub — no joystick (will retry on rescan)');
    }
  }

  Future<void> _hotplugFallback() async {
    if (_listeners.isEmpty) return;
    // Drop dead readers
    for (var i = _fallbackReaders.length - 1; i >= 0; i--) {
      if (!_fallbackReaders[i].isOpen) {
        try {
          await _fallbackSubs[i].cancel();
        } catch (_) {}
        try {
          await _fallbackReaders[i].dispose();
        } catch (_) {}
        _fallbackSubs.removeAt(i);
        _fallbackReaders.removeAt(i);
      }
    }
    await _openFallbackAll();
  }

  /// Re-list joysticks (display dock, pad power-on, lifecycle resume).
  void rescan() {
    if (_iso.isRunning) {
      _iso.requestRescan();
      return;
    }
    unawaited(_hotplugFallback());
  }

  void _deliver(GamepadEdge edge) {
    if (_listeners.isEmpty) return;
    // Touch priority — do not wait behind video raster work.
    SchedulerBinding.instance.scheduleTask(() {
      if (_listeners.isEmpty) return;
      try {
        _listeners.last(edge);
      } catch (e, st) {
        debugPrint('sdtv_input: hub listener error: $e\n$st');
      }
    }, Priority.touch);
  }

  Future<void> _tearDown() async {
    _fallbackHotplug?.cancel();
    _fallbackHotplug = null;
    await _sub?.cancel();
    _sub = null;
    await _iso.stop();
    for (final s in _fallbackSubs) {
      try {
        await s.cancel();
      } catch (_) {}
    }
    _fallbackSubs.clear();
    for (final r in _fallbackReaders) {
      try {
        await r.dispose();
      } catch (_) {}
    }
    _fallbackReaders.clear();
  }

  Future<void> release(void Function(GamepadEdge) onEdge) async {
    _listeners.remove(onEdge);
    if (_listeners.isNotEmpty) return;
    if (_closing != null) {
      await _closing;
      return;
    }
    _closing = _tearDown().whenComplete(() {
      debugPrint('sdtv_input: hub closed');
    });
    try {
      await _closing;
    } finally {
      _closing = null;
    }
  }

  Future<void> reassert(void Function(GamepadEdge) onEdge) async {
    await acquire(onEdge);
  }
}
