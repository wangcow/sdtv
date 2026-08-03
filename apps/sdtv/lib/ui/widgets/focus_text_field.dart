import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sdtv_input/sdtv_input.dart';

/// Focusable text field for couch login (keyboard, OSK, or gamepad).
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
    _focus.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    final has = _focus.hasFocus;
    if (has != _focused) setState(() => _focused = has);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    if (_ownsFocus) _focus.dispose();
    super.dispose();
  }

  void _goNext() {
    final moved = _focus.nextFocus();
    if (!moved) {
      widget.onSubmitted?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Actions(
      actions: <Type, Action<Intent>>{
        // D-pad / arrows while editing: leave field (Tab order).
        DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
          onInvoke: (intent) {
            final forward = intent.direction == TraversalDirection.down ||
                intent.direction == TraversalDirection.right;
            if (forward) {
              _goNext();
            } else {
              _focus.previousFocus();
            }
            return null;
          },
        ),
        NextFocusIntent: CallbackAction<NextFocusIntent>(
          onInvoke: (_) {
            _goNext();
            return null;
          },
        ),
        PreviousFocusIntent: CallbackAction<PreviousFocusIntent>(
          onInvoke: (_) {
            _focus.previousFocus();
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
          textInputAction: widget.textInputAction,
          onEditingComplete: _goNext,
          onSubmitted: (_) {
            _goNext();
            widget.onSubmitted?.call();
          },
        ),
      ),
    );
  }
}

/// Login form: gamepad + Tab traversal between fields.
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
        final primary = FocusManager.instance.primaryFocus;
        // Don't submit while typing in a field — move to next instead.
        if (primary?.context?.widget is EditableText) {
          primary?.nextFocus();
          return;
        }
        // Also detect EditableText under the focused node.
        final ctx = primary?.context;
        if (ctx != null &&
            ctx.findAncestorWidgetOfExactType<EditableText>() != null) {
          primary?.nextFocus();
          return;
        }
        onSubmit?.call();
      },
      onBack: onBack,
      extraShortcuts: {
        // Deck OSK / physical Tab
        const SingleActivator(LogicalKeyboardKey.tab): const NextFocusIntent(),
        const SingleActivator(LogicalKeyboardKey.tab, shift: true):
            const PreviousFocusIntent(),
        const SingleActivator(LogicalKeyboardKey.enter):
            const SdtvConfirmIntent(),
      },
      extraActions: {
        NextFocusIntent: CallbackAction<NextFocusIntent>(
          onInvoke: (_) {
            FocusManager.instance.primaryFocus?.nextFocus();
            return null;
          },
        ),
        PreviousFocusIntent: CallbackAction<PreviousFocusIntent>(
          onInvoke: (_) {
            FocusManager.instance.primaryFocus?.previousFocus();
            return null;
          },
        ),
      },
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: child,
      ),
    );
  }
}
