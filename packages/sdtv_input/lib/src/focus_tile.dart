import 'package:flutter/material.dart';

import 'actions.dart';

/// Large, high-contrast focusable tile for 10-foot / Deck UI.
class SdtvFocusTile extends StatefulWidget {
  const SdtvFocusTile({
    super.key,
    required this.label,
    this.onActivate,
    this.autofocus = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onActivate;
  final bool autofocus;
  final IconData? icon;

  @override
  State<SdtvFocusTile> createState() => _SdtvFocusTileState();
}

class _SdtvFocusTileState extends State<SdtvFocusTile> {
  late final FocusNode _node;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node = FocusNode(debugLabel: widget.label);
    _node.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (_focused != _node.hasFocus) {
      setState(() => _focused = _node.hasFocus);
    }
  }

  @override
  void dispose() {
    _node.removeListener(_onFocusChange);
    _node.dispose();
    super.dispose();
  }

  void _activate() {
    widget.onActivate?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = _focused
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final fg = _focused
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;

    // Per-tile Actions so gamepad Confirm activates *this* focused tile
    // instead of only the scope-level callback.
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _activate();
            return null;
          },
        ),
        SdtvConfirmIntent: CallbackAction<SdtvConfirmIntent>(
          onInvoke: (_) {
            _activate();
            return null;
          },
        ),
      },
      child: Focus(
        focusNode: _node,
        autofocus: widget.autofocus,
        child: GestureDetector(
          onTap: () {
            _node.requestFocus();
            _activate();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused
                    ? theme.colorScheme.primaryContainer
                    : Colors.transparent,
                width: 3,
              ),
              boxShadow: _focused
                  ? [
                      BoxShadow(
                        color:
                            theme.colorScheme.primary.withValues(alpha: 0.45),
                        blurRadius: 16,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, color: fg, size: 28),
                  const SizedBox(width: 12),
                ],
                Flexible(
                  child: Text(
                    widget.label,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: fg,
                      fontWeight:
                          _focused ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
