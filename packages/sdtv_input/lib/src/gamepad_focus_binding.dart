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

  /// True when focus is on a text field (or its EditableText child).
  bool _primaryIsTextInput() {
    final node = FocusManager.instance.primaryFocus;
    if (node == null) return false;

    // Common: focus node is attached directly to EditableText.
    final ctx = node.context;
    if (ctx != null) {
      if (ctx.widget is EditableText) return true;
      if (ctx.findAncestorWidgetOfExactType<EditableText>() != null) {
        return true;
      }
    }

    // TextField often uses a parent FocusNode whose descendants include EditableText.
    bool walk(FocusNode n) {
      for (final child in n.children) {
        final c = child.context;
        if (c?.widget is EditableText) return true;
        if (walk(child)) return true;
      }
      return false;
    }

    return walk(node);
  }

  /// Move focus like Tab / Shift+Tab (works better than DirectionalFocus in forms).
  void _traverse({required bool forward}) {
    final node = FocusManager.instance.primaryFocus;
    if (node == null) return;
    if (forward) {
      node.nextFocus();
    } else {
      node.previousFocus();
    }
  }

  void _onEdge(GamepadEdge edge) {
    if (!mounted) return;

    // App-level intents must run on this scope (parent Actions), not the focused
    // tile — otherwise Menu can fail to find a handler and feel like a no-op,
    // or Steam remaps ☰ to Escape which only hits Back.
    if (edge == GamepadEdge.menu || edge == GamepadEdge.back) {
      final intent = edge == GamepadEdge.menu
          ? const SdtvMenuIntent()
          : const SdtvBackIntent();
      try {
        final handled = Actions.maybeInvoke<Intent>(context, intent);
        debugPrint('sdtv_input: $edge invoke handled=$handled');
      } catch (e, st) {
        debugPrint('sdtv_input: $edge failed: $e\n$st');
      }
      return;
    }

    // Text fields: D-pad/stick = Tab traversal (not caret).
    if (_primaryIsTextInput()) {
      switch (edge) {
        case GamepadEdge.down:
        case GamepadEdge.right:
          _traverse(forward: true);
          return;
        case GamepadEdge.up:
        case GamepadEdge.left:
          _traverse(forward: false);
          return;
        case GamepadEdge.confirm:
          _traverse(forward: true);
          return;
        case GamepadEdge.pageUp:
          _traverse(forward: false);
          return;
        case GamepadEdge.pageDown:
          _traverse(forward: true);
          return;
        case GamepadEdge.back:
        case GamepadEdge.menu:
        case GamepadEdge.up:
        case GamepadEdge.down:
        case GamepadEdge.left:
        case GamepadEdge.right:
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
      // If directional focus didn't move (e.g. form fields), fall back to Tab order.
      if (handled == null &&
          (edge == GamepadEdge.down ||
              edge == GamepadEdge.right ||
              edge == GamepadEdge.up ||
              edge == GamepadEdge.left)) {
        _traverse(
          forward: edge == GamepadEdge.down || edge == GamepadEdge.right,
        );
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
