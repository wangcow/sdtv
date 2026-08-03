import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'actions.dart';
import 'input_callbacks.dart';
import 'joystick_hub.dart';
import 'linux_joystick.dart';

/// Binds the shared [SdtvJoystickHub] to focus / app callbacks.
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
  DateTime? _lastDirAt;
  DateTime? _lastConfirmAt;
  static const _dirCooldown = Duration(milliseconds: 250);
  static const _confirmCooldown = Duration(milliseconds: 280);

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
    // If the hub is already open (e.g. player pushed over browse), take the
    // top-of-stack immediately. A 400ms delay here left B/D-pad on the page
    // underneath — felt like "stuck until I jam buttons".
    final delay = SdtvJoystickHub.instance.isOpen
        ? Duration.zero
        : widget.startDelay;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.enabled) return;
      if (delay == Duration.zero) {
        unawaited(_acquire());
        return;
      }
      _startTimer = Timer(delay, () {
        if (mounted && widget.enabled) unawaited(_acquire());
      });
    });
  }

  Future<void> _acquire() async {
    if (!Platform.isLinux) return;
    // Always re-stack even if we thought we were acquired (route re-show).
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

  void _traverse({required bool forward}) {
    final node = FocusManager.instance.primaryFocus;
    if (node == null) return;
    if (forward) {
      node.nextFocus();
    } else {
      node.previousFocus();
    }
  }

  void _callApp(GamepadEdge edge) {
    final cbs = SdtvInputCallbacks.maybeOf(context);
    if (edge == GamepadEdge.back) {
      debugPrint('sdtv_input: BACK → onBack=${cbs?.onBack != null}');
      cbs?.onBack?.call();
      return;
    }
    if (edge == GamepadEdge.menu) {
      debugPrint('sdtv_input: MENU → onMenu=${cbs?.onMenu != null}');
      cbs?.onMenu?.call();
      return;
    }
    if (edge == GamepadEdge.confirm) {
      cbs?.onConfirm?.call();
    }
  }

  void _onEdge(GamepadEdge edge) {
    if (!mounted) return;

    // App chrome: call InheritedWidget callbacks directly (most reliable).
    if (edge == GamepadEdge.menu || edge == GamepadEdge.back) {
      _callApp(edge);
      return;
    }

    // Debounce directions: Steam Deck often sends js D-pad *and* a keyboard
    // arrow for one physical press — without this, forms skip every other field.
    final isDir = edge == GamepadEdge.up ||
        edge == GamepadEdge.down ||
        edge == GamepadEdge.left ||
        edge == GamepadEdge.right;
    if (isDir) {
      final now = DateTime.now();
      if (_lastDirAt != null && now.difference(_lastDirAt!) < _dirCooldown) {
        return;
      }
      _lastDirAt = now;
    }

    // Always route directions through Actions so pages can override
    // (login linear ring, browse 2-column). Do not use geometric focus here.
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

    try {
      if (edge == GamepadEdge.confirm) {
        // One physical A often arrives as js button + keyboard Enter/Space.
        final now = DateTime.now();
        if (_lastConfirmAt != null &&
            now.difference(_lastConfirmAt!) < _confirmCooldown) {
          return;
        }
        _lastConfirmAt = now;

        // Prefer focused control (tiles). Do NOT also call onConfirm — that
        // double-fired menu (About open then close, Cancel then play, etc.).
        final focusCtx =
            FocusManager.instance.primaryFocus?.context ?? context;
        final activated =
            Actions.maybeInvoke(focusCtx, const ActivateIntent());
        if (activated != null) return;

        final viaIntent =
            Actions.maybeInvoke(context, const SdtvConfirmIntent());
        if (viaIntent != null) return;

        SdtvInputCallbacks.maybeOf(context)?.onConfirm?.call();
        return;
      }

      // Prefer scope Actions (page overrides live here).
      final handled = Actions.maybeInvoke(context, intent);
      if (handled == null && SdtvTextFocusRegistry.primaryIsTextField) {
        _traverse(
          forward: edge == GamepadEdge.down ||
              edge == GamepadEdge.right ||
              edge == GamepadEdge.pageDown,
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
