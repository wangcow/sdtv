import 'dart:async';

import 'package:flutter/foundation.dart';

import 'linux_joystick.dart';

/// Process-wide joystick owner so nested [SdtvInputScope]s never open
/// `/dev/input/js*` twice (that was freezing the UI on dialogs / sign-out).
class SdtvJoystickHub {
  SdtvJoystickHub._();
  static final SdtvJoystickHub instance = SdtvJoystickHub._();

  LinuxJoystickReader? _reader;
  StreamSubscription<GamepadEdge>? _sub;
  final _listeners = <void Function(GamepadEdge)>{};
  Future<void>? _opening;
  int _refs = 0;

  String? get openPath => _reader?.openPath;

  Future<void> acquire(void Function(GamepadEdge) onEdge) async {
    _listeners.add(onEdge);
    _refs++;
    if (_reader != null) return;
    _opening ??= _open();
    try {
      await _opening;
    } finally {
      _opening = null;
    }
  }

  Future<void> _open() async {
    final reader = LinuxJoystickReader();
    final ok = await reader.open();
    if (!ok) {
      await reader.dispose();
      debugPrint('sdtv_input: hub — no joystick under /dev/input/js*');
      return;
    }
    _reader = reader;
    debugPrint('sdtv_input: hub open ${reader.openPath}');
    _sub = reader.events.listen(
      (edge) {
        // Copy to avoid concurrent modification if a listener releases.
        for (final l in List.of(_listeners)) {
          try {
            l(edge);
          } catch (e, st) {
            debugPrint('sdtv_input: hub listener error: $e\n$st');
          }
        }
      },
      onError: (Object e, StackTrace st) {
        debugPrint('sdtv_input: hub stream error: $e\n$st');
      },
    );
  }

  Future<void> release(void Function(GamepadEdge) onEdge) async {
    _listeners.remove(onEdge);
    _refs = (_refs - 1).clamp(0, 1 << 30);
    if (_refs > 0 || _listeners.isNotEmpty) return;
    await _sub?.cancel();
    _sub = null;
    await _reader?.dispose();
    _reader = null;
    debugPrint('sdtv_input: hub closed');
  }
}
