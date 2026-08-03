import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sdtv_input/sdtv_input.dart';

/// Focusable text field for couch login (keyboard or OSK).
class SdtvFocusTextField extends StatefulWidget {
  const SdtvFocusTextField({
    super.key,
    required this.controller,
    required this.label,
    this.obscureText = false,
    this.keyboardType,
    this.autofocus = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final bool obscureText;
  final TextInputType? keyboardType;
  final bool autofocus;
  final VoidCallback? onSubmitted;

  @override
  State<SdtvFocusTextField> createState() => _SdtvFocusTextFieldState();
}

class _SdtvFocusTextFieldState extends State<SdtvFocusTextField> {
  late final FocusNode _focus;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus = FocusNode(debugLabel: widget.label);
    _focus.addListener(() {
      final has = _focus.hasFocus;
      if (has != _focused) setState(() => _focused = has);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Override directional focus so gamepad D-pad leaves the field (Tab-like)
    // instead of moving the text caret forever.
    return Actions(
      actions: <Type, Action<Intent>>{
        DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
          onInvoke: (intent) {
            switch (intent.direction) {
              case TraversalDirection.down:
              case TraversalDirection.right:
                _focus.nextFocus();
              case TraversalDirection.up:
              case TraversalDirection.left:
                _focus.previousFocus();
            }
            return null;
          },
        ),
      },
      child: AnimatedContainer(
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
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => widget.onSubmitted?.call(),
        ),
      ),
    );
  }
}

/// Wraps a form so A/Enter on a focused non-text control submits.
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
        // If a TextField has focus, let it handle Enter; otherwise submit.
        final primary = FocusManager.instance.primaryFocus;
        if (primary?.context?.widget is EditableText) return;
        onSubmit?.call();
      },
      onBack: onBack,
      child: Shortcuts(
        shortcuts: {
          const SingleActivator(LogicalKeyboardKey.enter):
              const SdtvConfirmIntent(),
        },
        child: child,
      ),
    );
  }
}
