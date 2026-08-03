import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'actions.dart';
import 'linux_joystick.dart';

/// Binds [LinuxJoystickReader] to Flutter [Actions].
///
/// Starts **only after** several frames so gamepad setup cannot block the
/// native first-frame / window show path.
class SdtvGamepadBinding extends StatefulWidget {
  const SdtvGamepadBinding({
    super.key,
    required this.child,
    this.enabled = true,
    /// Delay after first frame before touching `/dev/input/js*`.
    this.startDelay = const Duration(milliseconds: 400),
  });

  final Widget child;
  final bool enabled;
  final Duration startDelay;

  @override
  State<SdtvGamepadBinding> createState() => _SdtvGamepadBindingState();
}

class _SdtvGamepadBindingState extends State<SdtvGamepadBinding> {
  LinuxJoystickReader? _reader;
  StreamSubscription<GamepadEdge>? _sub;
  Timer? _startTimer;
  String _status = 'pad: off';

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      _scheduleStart();
    }
  }

  @override
  void didUpdateWidget(SdtvGamepadBinding oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !oldWidget.enabled) {
      _scheduleStart();
    } else if (!widget.enabled && oldWidget.enabled) {
      unawaited(_stop());
    }
  }

  void _scheduleStart() {
    _startTimer?.cancel();
    // Wait for the first frame, then an extra delay so the window is mapped.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.enabled) return;
      _startTimer = Timer(widget.startDelay, () {
        if (mounted && widget.enabled) unawaited(_start());
      });
    });
  }

  Future<void> _start() async {
    if (!Platform.isLinux) return;
    try {
      await _stop();
      final reader = LinuxJoystickReader();
      final ok = await reader.open();
      if (!mounted) {
        await reader.dispose();
        return;
      }
      if (!ok) {
        await reader.dispose();
        _status = 'pad: none';
        debugPrint('sdtv_input: no joystick device under /dev/input/js*');
        return;
      }
      _reader = reader;
      _status = 'pad: ${reader.openPath}';
      debugPrint('sdtv_input: joystick open ${_status}');
      _sub = reader.events.listen(
        _onEdge,
        onError: (Object e, StackTrace st) {
          debugPrint('sdtv_input: joystick stream error: $e\n$st');
        },
      );
    } catch (e, st) {
      // Never let pad setup take down the UI.
      debugPrint('sdtv_input: joystick start failed: $e\n$st');
      _status = 'pad: error';
    }
  }

  Future<void> _stop() async {
    _startTimer?.cancel();
    _startTimer = null;
    await _sub?.cancel();
    _sub = null;
    await _reader?.dispose();
    _reader = null;
    _status = 'pad: off';
  }

  void _onEdge(GamepadEdge edge) {
    if (!mounted) return;

    final Intent intent;
    switch (edge) {
      case GamepadEdge.up:
        intent = const DirectionalFocusIntent(TraversalDirection.up);
      case GamepadEdge.down:
        intent = const DirectionalFocusIntent(TraversalDirection.down);
      case GamepadEdge.left:
        intent = const DirectionalFocusIntent(TraversalDirection.left);
      case GamepadEdge.right:
        intent = const DirectionalFocusIntent(TraversalDirection.right);
      case GamepadEdge.confirm:
        intent = const SdtvConfirmIntent();
      case GamepadEdge.back:
        intent = const SdtvBackIntent();
      case GamepadEdge.menu:
        intent = const SdtvMenuIntent();
      case GamepadEdge.pageUp:
        intent = const SdtvPageUpIntent();
      case GamepadEdge.pageDown:
        intent = const SdtvPageDownIntent();
    }

    final focusCtx = FocusManager.instance.primaryFocus?.context ?? context;
    try {
      final handled = Actions.maybeInvoke(focusCtx, intent);
      if (handled == null && edge == GamepadEdge.confirm) {
        Actions.maybeInvoke(focusCtx, const ActivateIntent());
      }
    } catch (e, st) {
      debugPrint('sdtv_input: invoke $edge failed: $e\n$st');
    }
  }

  @override
  void dispose() {
    unawaited(_stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;

  String get debugStatus => _status;
}
