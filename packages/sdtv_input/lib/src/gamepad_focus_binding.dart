import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'actions.dart';
import 'joystick_hub.dart';
import 'linux_joystick.dart';

/// Binds the shared [SdtvJoystickHub] to Flutter [Actions].
///
/// Starts after the first frame. Nested scopes share one device open.
class SdtvGamepadBinding extends StatefulWidget {
  const SdtvGamepadBinding({
    super.key,
    required this.child,
    this.enabled = true,
    this.startDelay = const Duration(milliseconds: 400),
  });

  final Widget child;
  final bool enabled;
  final Duration startDelay;

  @override
  State<SdtvGamepadBinding> createState() => _SdtvGamepadBindingState();
}

class _SdtvGamepadBindingState extends State<SdtvGamepadBinding> {
  Timer? _startTimer;
  bool _acquired = false;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _scheduleStart();
  }

  @override
  void didUpdateWidget(SdtvGamepadBinding oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !oldWidget.enabled) {
      _scheduleStart();
    } else if (!widget.enabled && oldWidget.enabled) {
      unawaited(_release());
    }
  }

  void _scheduleStart() {
    _startTimer?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.enabled) return;
      _startTimer = Timer(widget.startDelay, () {
        if (mounted && widget.enabled) unawaited(_acquire());
      });
    });
  }

  Future<void> _acquire() async {
    if (!Platform.isLinux || _acquired) return;
    try {
      await SdtvJoystickHub.instance.acquire(_onEdge);
      _acquired = true;
    } catch (e, st) {
      debugPrint('sdtv_input: hub acquire failed: $e\n$st');
    }
  }

  Future<void> _release() async {
    _startTimer?.cancel();
    _startTimer = null;
    if (!_acquired) return;
    _acquired = false;
    await SdtvJoystickHub.instance.release(_onEdge);
  }

  bool _primaryIsTextInput() {
    final node = FocusManager.instance.primaryFocus;
    if (node == null) return false;
    final ctx = node.context;
    if (ctx == null) return false;
    // TextField focus lands on EditableText.
    if (ctx.widget is EditableText) return true;
    return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _onEdge(GamepadEdge edge) {
    if (!mounted) return;

    // Text fields trap DirectionalFocus for caret movement. For couch nav,
    // treat stick/D-pad as Tab/Shift+Tab while a field is focused.
    if (_primaryIsTextInput()) {
      switch (edge) {
        case GamepadEdge.down:
        case GamepadEdge.right:
          FocusManager.instance.primaryFocus?.nextFocus();
          return;
        case GamepadEdge.up:
        case GamepadEdge.left:
          FocusManager.instance.primaryFocus?.previousFocus();
          return;
        case GamepadEdge.confirm:
          // Leave the field and activate default confirm on next frame if needed.
          FocusManager.instance.primaryFocus?.nextFocus();
          return;
        case GamepadEdge.back:
          FocusManager.instance.primaryFocus?.unfocus();
          // Fall through to Back intent on the scope.
          break;
        case GamepadEdge.menu:
        case GamepadEdge.pageUp:
        case GamepadEdge.pageDown:
          break;
      }
    }

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
    unawaited(_release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
