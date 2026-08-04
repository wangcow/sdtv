import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sdtv_core/sdtv_core.dart';
import 'package:sdtv_input/sdtv_input.dart';

import '../state/session_controller.dart';

/// Login / home. Selection is an **integer index**, not Flutter focus geometry.
///
/// Steam Deck Game Mode often emits joystick D-pad *and* a keyboard arrow for
/// one physical press. Focus-based traversal double-stepped and skipped fields.
/// Here D-pad only changes [_selected]; text fields take focus only when
/// selected so the OSK can type.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.session});

  final SessionController session;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  static const _itemCount = 5; // demo, url, user, pass, connect

  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();

  final _urlFocus = FocusNode(debugLabel: 'url');
  final _userFocus = FocusNode(debugLabel: 'user');
  final _passFocus = FocusNode(debugLabel: 'pass');

  int _selected = 0;
  bool _busy = false;
  bool _showPassword = false;
  String? _localError;

  /// Ignore duplicate nav from js + keyboard arrow within this window.
  DateTime? _lastNav;
  static const _cooldown = Duration(milliseconds: 220);

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    _urlFocus.dispose();
    _userFocus.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  bool get _isFieldSelected => _selected >= 1 && _selected <= 3;

  void _nav(int delta) {
    final now = DateTime.now();
    if (_lastNav != null && now.difference(_lastNav!) < _cooldown) {
      return;
    }
    _lastNav = now;

    setState(() {
      _selected = (_selected + delta).clamp(0, _itemCount - 1);
    });
    _syncFieldFocus();
  }

  void _syncFieldFocus() {
    // Only the selected text field should hold keyboard focus (for OSK).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (_selected) {
        case 1:
          _urlFocus.requestFocus();
        case 2:
          _userFocus.requestFocus();
        case 3:
          _passFocus.requestFocus();
        default:
          _urlFocus.unfocus();
          _userFocus.unfocus();
          _passFocus.unfocus();
          FocusManager.instance.primaryFocus?.unfocus();
      }
    });
  }

  Future<void> _activate() async {
    switch (_selected) {
      case 0:
        await _demo();
      case 1:
      case 2:
        _nav(1);
      case 3:
        await _connect();
      case 4:
        await _connect();
    }
  }

  Future<void> _demo() async {
    setState(() {
      _busy = true;
      _localError = null;
    });
    await widget.session.connectDemo();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _connect() async {
    final url = _url.text.trim();
    final user = _user.text.trim();
    final pass = _pass.text;
    if (url.isEmpty || user.isEmpty || pass.isEmpty) {
      setState(
        () => _localError =
            'Enter server URL, username, and password — or use Demo.',
      );
      return;
    }
    if (!XtreamCredentials.isPlausibleServerUrl(url)) {
      setState(
        () => _localError =
            'Server URL must be like http://host:8080 (not a short placeholder). '
            'Or use “Continue with demo playlist”.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _localError = null;
    });
    await widget.session.connectRemote(
      XtreamCredentials(baseUrl: url, username: user, password: pass),
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final err = _localError ?? widget.session.errorMessage;

    return SdtvInputScope(
      onConfirm: () {
        if (!_busy) unawaited(_activate());
      },
      // All directions: change selection index only (no Flutter focus walk).
      onDirection: (dir) {
        final forward = dir == TraversalDirection.down ||
            dir == TraversalDirection.right;
        _nav(forward ? 1 : -1);
      },
      extraActions: {
        DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
          onInvoke: (intent) {
            final forward = intent.direction == TraversalDirection.down ||
                intent.direction == TraversalDirection.right;
            _nav(forward ? 1 : -1);
            return null;
          },
        ),
        NextFocusIntent: CallbackAction<NextFocusIntent>(
          onInvoke: (_) {
            _nav(1);
            return null;
          },
        ),
        PreviousFocusIntent: CallbackAction<PreviousFocusIntent>(
          onInvoke: (_) {
            _nav(-1);
            return null;
          },
        ),
      },
      child: Shortcuts(
        shortcuts: {
          // Steam injects these for D-pad; route through same _nav + cooldown.
          const SingleActivator(LogicalKeyboardKey.arrowDown):
              const _HomeNavIntent(1),
          const SingleActivator(LogicalKeyboardKey.arrowRight):
              const _HomeNavIntent(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp):
              const _HomeNavIntent(-1),
          const SingleActivator(LogicalKeyboardKey.arrowLeft):
              const _HomeNavIntent(-1),
          const SingleActivator(LogicalKeyboardKey.tab):
              const _HomeNavIntent(1),
          const SingleActivator(LogicalKeyboardKey.tab, shift: true):
              const _HomeNavIntent(-1),
          const SingleActivator(LogicalKeyboardKey.enter):
              const SdtvConfirmIntent(),
        },
        child: Actions(
          actions: {
            _HomeNavIntent: CallbackAction<_HomeNavIntent>(
              onInvoke: (i) {
                _nav(i.delta);
                return null;
              },
            ),
          },
          child: Scaffold(
            body: SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
                        child: ListView(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 32,
                            vertical: 28,
                          ),
                          children: [
                            Text(
                              'sdtv',
                              style: theme.textTheme.displaySmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.4,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Steam Deck–first IPTV player',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Player only — bring your own Xtream Codes credentials. '
                              'Demo uses offline mock data. Connect hits your real '
                              'provider (URL + user + pass).',
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 28),
                            _SelectTile(
                              selected: _selected == 0,
                              label: 'Continue with demo playlist',
                              icon: Icons.play_circle_outline,
                              onTap: () {
                                setState(() => _selected = 0);
                                if (!_busy) _demo();
                              },
                            ),
                            const SizedBox(height: 28),
                            Text(
                              'OR CONNECT XTREAM CODES',
                              style: theme.textTheme.labelSmall?.copyWith(
                                letterSpacing: 1.2,
                                color: theme.colorScheme.outline,
                              ),
                            ),
                            const SizedBox(height: 12),
                            _SelectField(
                              selected: _selected == 1,
                              label: 'Server URL (http://host:port)',
                              controller: _url,
                              focusNode: _urlFocus,
                              keyboardType: TextInputType.url,
                              onTap: () {
                                setState(() => _selected = 1);
                                _syncFieldFocus();
                              },
                            ),
                            const SizedBox(height: 12),
                            _SelectField(
                              selected: _selected == 2,
                              label: 'Username',
                              controller: _user,
                              focusNode: _userFocus,
                              onTap: () {
                                setState(() => _selected = 2);
                                _syncFieldFocus();
                              },
                            ),
                            const SizedBox(height: 12),
                            _SelectField(
                              selected: _selected == 3,
                              label: 'Password',
                              controller: _pass,
                              focusNode: _passFocus,
                              obscureText: !_showPassword,
                              textInputAction: TextInputAction.done,
                              onSubmitted: _busy ? null : _connect,
                              onTap: () {
                                setState(() => _selected = 3);
                                _syncFieldFocus();
                              },
                              suffix: IconButton(
                                tooltip: _showPassword
                                    ? 'Hide password'
                                    : 'Show password',
                                icon: Icon(
                                  _showPassword
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                ),
                                onPressed: () {
                                  setState(() => _showPassword = !_showPassword);
                                },
                              ),
                            ),
                            const SizedBox(height: 20),
                            _SelectTile(
                              selected: _selected == 4,
                              label: _busy
                                  ? 'Connecting…'
                                  : 'Connect to provider',
                              icon: Icons.login,
                              onTap: () {
                                setState(() => _selected = 4);
                                if (!_busy) _connect();
                              },
                            ),
                            if (err != null) ...[
                              const SizedBox(height: 20),
                              Text(
                                err,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ],
                            if (_isFieldSelected) ...[
                              const SizedBox(height: 16),
                              Text(
                                _selected == 3
                                    ? 'Type with OSK · eye icon shows password · A = connect'
                                    : 'Type with OSK · D-pad up/down changes field · A = next / connect',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.outline,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    child: Text(
                      'Product of the Wangcow Corporation',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeNavIntent extends Intent {
  const _HomeNavIntent(this.delta);
  final int delta;
}

/// Visual selection chrome (not Focus-driven).
class _SelectTile extends StatelessWidget {
  const _SelectTile({
    required this.selected,
    required this.label,
    required this.onTap,
    this.icon,
  });

  final bool selected;
  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final fg =
        selected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primaryContainer
                : Colors.transparent,
            width: 3,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: theme.colorScheme.primary.withValues(alpha: 0.45),
                    blurRadius: 16,
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, color: fg, size: 28),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectField extends StatelessWidget {
  const _SelectField({
    required this.selected,
    required this.label,
    required this.controller,
    required this.focusNode,
    required this.onTap,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
    this.suffix,
  });

  final bool selected;
  final String label;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onTap;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction textInputAction;
  final VoidCallback? onSubmitted;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? theme.colorScheme.primary : Colors.transparent,
            width: 3,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: theme.colorScheme.primary.withValues(alpha: 0.35),
                    blurRadius: 12,
                  ),
                ]
              : null,
        ),
        child: TextField(
          focusNode: focusNode,
          controller: controller,
          obscureText: obscureText,
          keyboardType: keyboardType,
          // Don't autofocus — parent assigns focus when selected.
          style: theme.textTheme.titleMedium,
          decoration: InputDecoration(
            labelText: label,
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            suffixIcon: suffix,
          ),
          textInputAction: textInputAction,
          // Typing only; D-pad is owned by the page index.
          onTap: onTap,
          onSubmitted: (_) => onSubmitted?.call(),
        ),
      ),
    );
  }
}
