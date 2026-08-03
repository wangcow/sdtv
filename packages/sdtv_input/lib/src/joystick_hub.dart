import 'dart:async';

import 'package:flutter/foundation.dart';

import 'linux_joystick.dart';

/// Process-wide joystick owner. Nested scopes share one device; only the
/// **topmost** (last acquired) listener receives events.
///
/// Open/close is serialized. A previous bug let a new page [acquire] while the
/// old page was still disposing the device (`_reader != null` but already
/// closing). The new page kept a dead hub until something else reopened it
/// (e.g. opening the player) — D-pad dead after demo login / after sign-out.
class SdtvJoystickHub {
  SdtvJoystickHub._();
  static final SdtvJoystickHub instance = SdtvJoystickHub._();

  LinuxJoystickReader? _reader;
  StreamSubscription<GamepadEdge>? _sub;
  final _listeners = <void Function(GamepadEdge)>[];
  Future<void>? _opening;
  Future<void>? _closing;

  String? get openPath => _reader?.openPath;

  /// True when a live device pump is running.
  bool get isOpen => _reader != null && _reader!.isOpen;

  int get listenerCount => _listeners.length;

  Future<void> acquire(void Function(GamepadEdge) onEdge) async {
    // Re-stack: this listener becomes topmost.
    _listeners.remove(onEdge);
    _listeners.add(onEdge);
    await _ensureOpen();
  }

  /// Guarantee a live device while anyone is listening.
  Future<void> _ensureOpen() async {
    // Wait out any in-flight close so we don't attach to a dying reader.
    final closing = _closing;
    if (closing != null) {
      await closing;
    }

    if (_reader != null && _reader!.isOpen) {
      return;
    }

    // Stale reader object (closed pump) — drop it.
    if (_reader != null) {
      await _tearDownReader();
    }

    if (_opening != null) {
      await _opening;
      if (_reader != null && _reader!.isOpen) return;
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
    // Retry once — previous page may still be releasing the fd for a beat.
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_listeners.isEmpty) return;
      final reader = LinuxJoystickReader();
      final ok = await reader.open();
      if (ok) {
        _reader = reader;
        debugPrint('sdtv_input: hub open ${reader.openPath}');
        _sub = reader.events.listen(
          (edge) {
            if (_listeners.isEmpty) return;
            try {
              _listeners.last(edge);
            } catch (e, st) {
              debugPrint('sdtv_input: hub listener error: $e\n$st');
            }
          },
          onError: (Object e, StackTrace st) {
            debugPrint('sdtv_input: hub stream error: $e\n$st');
          },
          onDone: () {
            debugPrint('sdtv_input: hub stream done');
            // Device gone — clear so next acquire reopens.
            unawaited(_onPumpDone());
          },
        );
        return;
      }
      await reader.dispose();
      debugPrint('sdtv_input: hub open attempt ${attempt + 1} failed');
      await Future<void>.delayed(Duration(milliseconds: 80 * (attempt + 1)));
    }
    debugPrint('sdtv_input: hub — no joystick under /dev/input/js*');
  }

  Future<void> _onPumpDone() async {
    // Only tear down if this is still our reader.
    if (_listeners.isEmpty) {
      await _tearDownReader();
      return;
    }
    // Listeners still want input — reopen.
    await _tearDownReader();
    await _ensureOpen();
  }

  Future<void> _tearDownReader() async {
    await _sub?.cancel();
    _sub = null;
    final r = _reader;
    _reader = null;
    try {
      await r?.dispose();
    } catch (_) {}
  }

  Future<void> release(void Function(GamepadEdge) onEdge) async {
    _listeners.remove(onEdge);
    if (_listeners.isNotEmpty) {
      // Another page still owns the stack; leave device open.
      return;
    }
    // Last listener — close device (serialized with acquire).
    if (_closing != null) {
      await _closing;
      return;
    }
    _closing = _tearDownReader().whenComplete(() {
      debugPrint('sdtv_input: hub closed');
    });
    try {
      await _closing;
    } finally {
      _closing = null;
    }
  }

  /// Force top-of-stack rebind + live device (call after route/phase changes).
  Future<void> reassert(void Function(GamepadEdge) onEdge) async {
    await acquire(onEdge);
  }
}
