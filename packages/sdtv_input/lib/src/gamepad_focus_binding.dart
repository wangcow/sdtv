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
    /// Kept for API compat; handoff uses double post-frame, not a long delay.
    this.startDelay = Duration.zero,
  });

  final Widget child;
  final bool enabled;
  final Duration startDelay;

  @override
  State<SdtvGamepadBinding> createState() => _SdtvGamepadBindingState();
}

class _SdtvGamepadBindingState extends State<SdtvGamepadBinding>
    with WidgetsBindingObserver {
  bool _acquired = false;
  DateTime? _lastDirAt;
  DateTime? _lastConfirmAt;
  static const _dirCooldown = Duration(milliseconds: 250);
  static const _confirmCooldown = Duration(milliseconds: 280);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.enabled) {
      // Deck sleep / Steam overlay can drop js; reassert ownership.
      unawaited(_acquire());
    }
  }

  /// Wait until the previous page's dispose/release has run, then take the hub.
  /// Avoids racing a closing `/dev/input/js*` (dead D-pad until player reopen).
  void _scheduleStart() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.enabled) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.enabled) return;
        unawaited(_acquire());
      });
    });
  }

  Future<void> _acquire() async {
    if (!Platform.isLinux || !widget.enabled) return;
    try {
      await SdtvJoystickHub.instance.acquire(_onEdge);
      _acquired = true;
      debugPrint(
        'sdtv_input: binding acquired (listeners=${SdtvJoystickHub.instance.listenerCount} open=${SdtvJoystickHub.instance.isOpen})',
      );
    } catch (e, st) {
      debugPrint('sdtv_input: hub acquire failed: $e\n$st');
    }
  }

  Future<void> _release() async {
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

    final cbs = SdtvInputCallbacks.maybeOf(context);

    // Bumpers — same direct path as B (Actions fails under playing video).
    if (edge == GamepadEdge.pageUp) {
      if (cbs?.onPageUp != null) {
        cbs!.onPageUp!();
        return;
      }
    }
    if (edge == GamepadEdge.pageDown) {
      if (cbs?.onPageDown != null) {
        cbs!.onPageDown!();
        return;
      }
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

      if (cbs?.onDirection != null) {
        final TraversalDirection dir;
        switch (edge) {
          case GamepadEdge.up:
            dir = TraversalDirection.up;
          case GamepadEdge.down:
            dir = TraversalDirection.down;
          case GamepadEdge.left:
            dir = TraversalDirection.left;
          case GamepadEdge.right:
            dir = TraversalDirection.right;
          default:
            return;
        }
        cbs!.onDirection!(dir);
        return;
      }
    }

    // Fallback: Actions (login/browse keyboard + pad when no direct callbacks).
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

        cbs?.onConfirm?.call();
        return;
      }

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
    WidgetsBinding.instance.removeObserver(this);
    // Sync flag first so a racing schedule doesn't re-acquire after release.
    unawaited(_release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
