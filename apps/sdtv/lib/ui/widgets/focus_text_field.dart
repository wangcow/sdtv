import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sdtv_input/sdtv_input.dart';

/// Focusable text field for couch login.
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
    /// When false, arrows are left to the parent form (avoids double-steps with
    /// Steam injecting both js D-pad and keyboard arrows).
    this.handleArrowKeys = true,
  });

  final TextEditingController controller;
  final String label;
  final bool obscureText;
  final TextInputType? keyboardType;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback? onSubmitted;
  final TextInputAction textInputAction;
  final bool handleArrowKeys;

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

    // Tab always advances (Deck OSK). Do not also let it bubble.
    if (key == LogicalKeyboardKey.tab) {
      final shift = HardwareKeyboard.instance.isShiftPressed;
      if (shift) {
        node.previousFocus();
      } else {
        final moved = node.nextFocus();
        if (!moved) widget.onSubmitted?.call();
      }
      return KeyEventResult.handled;
    }

    if (!widget.handleArrowKeys) {
      // Parent form owns D-pad / arrows (with debounce). Ignore here so we
      // don't double-step when Steam sends js + keyboard for one press.
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowRight) {
      final moved = node.nextFocus();
      if (!moved) widget.onSubmitted?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowLeft) {
      node.previousFocus();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
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
        onEditingComplete: () {
          final moved = _focus.nextFocus();
          if (!moved) widget.onSubmitted?.call();
        },
        onSubmitted: (_) {
          final moved = _focus.nextFocus();
          if (!moved) widget.onSubmitted?.call();
          widget.onSubmitted?.call();
        },
      ),
    );
  }
}
