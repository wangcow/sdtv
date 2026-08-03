import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'input_callbacks.dart';
import 'joystick_hub.dart';
import 'linux_joystick.dart';
import 'pad_router.dart';

/// Single process joystick + global keyboard → [SdtvPadRouter].
///
/// Mount **once** at the app root.
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
  DateTime? _lastBackAt;
  static const _dirCooldown = Duration(milliseconds: 160);
  static const _confirmCooldown = Duration(milliseconds: 220);
  static const _backCooldown = Duration(milliseconds: 220);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKey);
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
        'sdtv_input: root pad open '
        '(path=${SdtvJoystickHub.instance.openPath} '
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

  /// Steam often injects keyboard for face buttons. Handle globally so we do
  /// not depend on focus once the video surface is active.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (SdtvPadRouter.instance.depth == 0) return false;

    final k = event.logicalKey;
    final typing = SdtvTextFocusRegistry.primaryIsTextField;

    // Never steal Space (or printable typing) from OSK / password fields.
    if (typing && k == LogicalKeyboardKey.space) return false;

    GamepadEdge? edge;
    if (k == LogicalKeyboardKey.escape ||
        k == LogicalKeyboardKey.gameButtonB ||
        k == LogicalKeyboardKey.goBack ||
        k == LogicalKeyboardKey.browserBack) {
      edge = GamepadEdge.back;
    } else if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.gameButtonA ||
        k == LogicalKeyboardKey.select ||
        (!typing && k == LogicalKeyboardKey.space)) {
      edge = GamepadEdge.confirm;
    } else if (k == LogicalKeyboardKey.arrowUp) {
      edge = GamepadEdge.up;
    } else if (k == LogicalKeyboardKey.arrowDown) {
      edge = GamepadEdge.down;
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      edge = GamepadEdge.left;
    } else if (k == LogicalKeyboardKey.arrowRight) {
      edge = GamepadEdge.right;
    } else if (k == LogicalKeyboardKey.pageUp ||
        k == LogicalKeyboardKey.gameButtonLeft1) {
      edge = GamepadEdge.pageUp;
    } else if (k == LogicalKeyboardKey.pageDown ||
        k == LogicalKeyboardKey.gameButtonRight1) {
      edge = GamepadEdge.pageDown;
    } else if (k == LogicalKeyboardKey.gameButtonStart ||
        k == LogicalKeyboardKey.gameButtonY ||
        k == LogicalKeyboardKey.contextMenu) {
      edge = GamepadEdge.menu;
    }

    if (edge == null) return false;
    _onEdge(edge);
    return true; // consume — avoid double-handling via Shortcuts
  }

  void _onEdge(GamepadEdge edge) {
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

    if (edge == GamepadEdge.back || edge == GamepadEdge.menu) {
      final now = DateTime.now();
      if (_lastBackAt != null && now.difference(_lastBackAt!) < _backCooldown) {
        return;
      }
      _lastBackAt = now;
    }

    if (SdtvPadRouter.instance.dispatch(edge)) {
      return;
    }

    // Fallback InheritedWidget path (tests / no layer).
    if (!mounted) return;
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
    HardwareKeyboard.instance.removeHandler(_onKey);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
