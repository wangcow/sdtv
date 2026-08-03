import 'package:flutter/widgets.dart';

import 'linux_joystick.dart';

/// Page-owned pad handlers. Stored as a stack; only the top layer receives
/// joystick edges. Callbacks are plain functions — **no [BuildContext]** — so
/// dispatch still works when media_kit video is compositing and InheritedWidget
/// / nested [SdtvGamepadBinding] lookups fail.
class SdtvPadLayer {
  VoidCallback? onConfirm;
  VoidCallback? onBack;
  VoidCallback? onMenu;
  void Function(TraversalDirection direction)? onDirection;
  VoidCallback? onPageUp;
  VoidCallback? onPageDown;
}

/// Process-wide stack of [SdtvPadLayer]s. One app-level joystick reader calls
/// [dispatch]; pages [push]/[pop] in initState/dispose.
class SdtvPadRouter {
  SdtvPadRouter._();
  static final SdtvPadRouter instance = SdtvPadRouter._();

  final _stack = <SdtvPadLayer>[];

  int get depth => _stack.length;

  SdtvPadLayer? get top => _stack.isEmpty ? null : _stack.last;

  void push(SdtvPadLayer layer) {
    _stack.remove(layer);
    _stack.add(layer);
  }

  void pop(SdtvPadLayer layer) {
    _stack.remove(layer);
  }

  /// Handle a joystick edge. Returns true if a layer consumed it.
  bool dispatch(GamepadEdge edge) {
    final layer = top;
    if (layer == null) return false;

    switch (edge) {
      case GamepadEdge.back:
        if (layer.onBack == null) return false;
        layer.onBack!();
        return true;
      case GamepadEdge.menu:
        if (layer.onMenu == null) return false;
        layer.onMenu!();
        return true;
      case GamepadEdge.confirm:
        if (layer.onConfirm == null) return false;
        layer.onConfirm!();
        return true;
      case GamepadEdge.pageUp:
        if (layer.onPageUp != null) {
          layer.onPageUp!();
          return true;
        }
        // Fall through: treat as up if no bumper handler.
        if (layer.onDirection != null) {
          layer.onDirection!(TraversalDirection.up);
          return true;
        }
        return false;
      case GamepadEdge.pageDown:
        if (layer.onPageDown != null) {
          layer.onPageDown!();
          return true;
        }
        if (layer.onDirection != null) {
          layer.onDirection!(TraversalDirection.down);
          return true;
        }
        return false;
      case GamepadEdge.up:
        if (layer.onDirection == null) return false;
        layer.onDirection!(TraversalDirection.up);
        return true;
      case GamepadEdge.down:
        if (layer.onDirection == null) return false;
        layer.onDirection!(TraversalDirection.down);
        return true;
      case GamepadEdge.left:
        if (layer.onDirection == null) return false;
        layer.onDirection!(TraversalDirection.left);
        return true;
      case GamepadEdge.right:
        if (layer.onDirection == null) return false;
        layer.onDirection!(TraversalDirection.right);
        return true;
    }
  }
}
