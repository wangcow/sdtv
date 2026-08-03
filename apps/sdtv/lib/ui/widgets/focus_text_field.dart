import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sdtv_input/sdtv_input.dart';

/// Focusable text field for couch login (keyboard, Deck OSK, or gamepad).
class SdtvFocusTextField extends StatefulWidget {
  const SdtvFocusTextField({
    super.key,
    required this.controller,
    required this.label,
    this.obscureText = false,
    this.keyboardType,
    this.autofocus = false,
    this.focusNode,
    this.onSubmitted,
    this.textInputAction = TextInputAction.next,
  });

  final TextEditingController controller;
  final String label;
  final bool obscureText;
  final TextInputType? keyboardType;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback? onSubmitted;
  final TextInputAction textInputAction;

  @override
  State<SdtvFocusTextField> createState() => _SdtvFocusTextFieldState();
}

class _SdtvFocusTextFieldState extends State<SdtvFocusTextField> {
  late final FocusNode _focus;
  late final bool _ownsFocus;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _ownsFocus = widget.focusNode == null;
    _focus = widget.focusNode ?? FocusNode(debugLabel: widget.label);
    _focus
      ..onKeyEvent = _onKeyEvent
      ..addListener(_onFocusChange);
    SdtvTextFocusRegistry.register(_focus);
  }

  void _onFocusChange() {
    final has = _focus.hasFocus;
    if (has != _focused) setState(() => _focused = has);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;

    // Deck OSK / hardware Tab
    if (key == LogicalKeyboardKey.tab) {
      final shift = HardwareKeyboard.instance.isShiftPressed;
      if (shift) {
        node.previousFocus();
      } else {
        _goNext(node);
      }
      return KeyEventResult.handled;
    }

    // Arrows leave the field (couch form navigation)
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowRight) {
      _goNext(node);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowLeft) {
      node.previousFocus();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _goNext(FocusNode node) {
    final moved = node.nextFocus();
    if (!moved) {
      widget.onSubmitted?.call();
    }
  }

  @override
  void dispose() {
    SdtvTextFocusRegistry.unregister(_focus);
    _focus.removeListener(_onFocusChange);
    _focus.onKeyEvent = null;
    if (_ownsFocus) _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _focused ? theme.colorScheme.primary : Colors.transparent,
          width: 3,
        ),
        boxShadow: _focused
            ? [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.35),
                  blurRadius: 12,
                ),
              ]
            : null,
      ),
      child: TextField(
        focusNode: _focus,
        controller: widget.controller,
        obscureText: widget.obscureText,
        keyboardType: widget.keyboardType,
        autofocus: widget.autofocus,
        style: theme.textTheme.titleMedium,
        decoration: InputDecoration(
          labelText: widget.label,
          filled: true,
          fillColor: theme.colorScheme.surfaceContainerHighest,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        ),
        textInputAction: widget.textInputAction,
        onEditingComplete: () => _goNext(_focus),
        onSubmitted: (_) {
          _goNext(_focus);
          widget.onSubmitted?.call();
        },
      ),
    );
  }
}

/// Login form scope with ordered focus + Tab.
class SdtvLoginFormScope extends StatelessWidget {
  const SdtvLoginFormScope({
    super.key,
    required this.child,
    this.onSubmit,
    this.onBack,
  });

  final Widget child;
  final VoidCallback? onSubmit;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return SdtvInputScope(
      onConfirm: () {
        if (SdtvTextFocusRegistry.primaryIsTextField) {
          FocusManager.instance.primaryFocus?.nextFocus();
          return;
        }
        onSubmit?.call();
      },
      onBack: onBack,
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: child,
      ),
    );
  }
}
