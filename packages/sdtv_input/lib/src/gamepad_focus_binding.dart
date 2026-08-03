import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'actions.dart';
import 'input_callbacks.dart';
import 'joystick_hub.dart';
import 'linux_joystick.dart';
import 'pad_router.dart';

/// Single process joystick → [SdtvPadRouter] (and optional legacy fallback).
///
/// Mount **once** at the app root. Pages register handlers via [SdtvInputScope]
/// / [SdtvPadRouter] — do not nest this binding under the video player.
class SdtvGamepadBinding extends StatefulWidget {
  const SdtvGamepadBinding({
    super.key,
    required this.child,
    this.enabled = true,
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
  static const _dirCooldown = Duration(milliseconds: 180);
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
      unawaited(_acquire());
    }
  }

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
        'sdtv_input: root pad binding open '
        '(listeners=${SdtvJoystickHub.instance.listenerCount} '
        'layers=${SdtvPadRouter.instance.depth})',
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

  void _onEdge(GamepadEdge edge) {
    if (!mounted) return;

    // Debounce D-pad only (not B/A/bumpers).
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

    if (edge == GamepadEdge.confirm) {
      final now = DateTime.now();
      if (_lastConfirmAt != null &&
          now.difference(_lastConfirmAt!) < _confirmCooldown) {
        return;
      }
      _lastConfirmAt = now;
    }

    // Primary path: stack of page layers (no InheritedWidget / no nested bind).
    if (SdtvPadRouter.instance.dispatch(edge)) {
      return;
    }

    // Fallback for tests / scopes that only use InheritedWidget callbacks.
    final cbs = SdtvInputCallbacks.maybeOf(context);
    if (cbs == null) return;

    switch (edge) {
      case GamepadEdge.back:
        cbs.onBack?.call();
      case GamepadEdge.menu:
        cbs.onMenu?.call();
      case GamepadEdge.confirm:
        cbs.onConfirm?.call();
      case GamepadEdge.pageUp:
        cbs.onPageUp?.call();
      case GamepadEdge.pageDown:
        cbs.onPageDown?.call();
      case GamepadEdge.up:
        cbs.onDirection?.call(TraversalDirection.up);
      case GamepadEdge.down:
        cbs.onDirection?.call(TraversalDirection.down);
      case GamepadEdge.left:
        cbs.onDirection?.call(TraversalDirection.left);
      case GamepadEdge.right:
        cbs.onDirection?.call(TraversalDirection.right);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
