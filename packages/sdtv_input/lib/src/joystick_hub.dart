import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'joystick_isolate.dart';
import 'linux_joystick.dart';

/// Process-wide joystick owner. Prefers a **background isolate** so media_kit
/// video frames cannot starve pad reads on the UI isolate.
class SdtvJoystickHub {
  SdtvJoystickHub._();
  static final SdtvJoystickHub instance = SdtvJoystickHub._();

  final _listeners = <void Function(GamepadEdge)>[];
  final _iso = JoystickIsolate();
  StreamSubscription<GamepadEdge>? _sub;
  LinuxJoystickReader? _fallback;
  StreamSubscription<GamepadEdge>? _fallbackSub;
  Future<void>? _opening;
  Future<void>? _closing;

  bool get isOpen =>
      _iso.isRunning || (_fallback != null && _fallback!.isOpen);

  int get listenerCount => _listeners.length;

  String? get openPath =>
      _fallback?.openPath ?? (_iso.isRunning ? 'isolate' : null);

  Future<void> acquire(void Function(GamepadEdge) onEdge) async {
    _listeners.remove(onEdge);
    _listeners.add(onEdge);
    await _ensureOpen();
  }

  Future<void> _ensureOpen() async {
    final closing = _closing;
    if (closing != null) await closing;

    if (isOpen) return;
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

    for (var attempt = 0; attempt < 3; attempt++) {
      if (_listeners.isEmpty) return;
      final reader = LinuxJoystickReader();
      final opened = await reader.open();
      if (opened) {
        _fallback = reader;
        debugPrint('sdtv_input: hub fallback open ${reader.openPath}');
        _fallbackSub = reader.events.listen(_deliver);
        return;
      }
      await reader.dispose();
      await Future<void>.delayed(Duration(milliseconds: 80 * (attempt + 1)));
    }
    debugPrint('sdtv_input: hub — no joystick');
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
    await _sub?.cancel();
    _sub = null;
    await _iso.stop();
    await _fallbackSub?.cancel();
    _fallbackSub = null;
    final f = _fallback;
    _fallback = null;
    try {
      await f?.dispose();
    } catch (_) {}
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
