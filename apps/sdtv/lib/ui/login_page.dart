import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sdtv_core/sdtv_core.dart';
import 'package:sdtv_input/sdtv_input.dart';

import '../state/session_controller.dart';

/// How the user wants to load channels after Demo.
enum _SourceKind { none, m3u, xtream }

/// Login / home. Selection is an **integer index**, not Flutter focus geometry.
///
/// Layout (no endless dual forms):
///   0 Demo
///   1 M3U  ·  2 Xtream   ← pick one source
///   then only fields for the active source
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.session});

  final SessionController session;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _m3uUrl = TextEditingController();
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();

  final _m3uFocus = FocusNode(debugLabel: 'm3u');
  final _urlFocus = FocusNode(debugLabel: 'url');
  final _userFocus = FocusNode(debugLabel: 'user');
  final _passFocus = FocusNode(debugLabel: 'pass');

  int _selected = 0;
  _SourceKind _source = _SourceKind.none;
  bool _busy = false;
  bool _showPassword = false;
  String? _localError;

  DateTime? _lastNav;
  static const _cooldown = Duration(milliseconds: 220);

  /// Fixed header: demo + two source choosers.
  static const _headerCount = 3;

  int get _itemCount {
    switch (_source) {
      case _SourceKind.none:
        return _headerCount; // 0..2
      case _SourceKind.m3u:
        return _headerCount + 2; // + url, open
      case _SourceKind.xtream:
        return _headerCount + 4; // + server, user, pass, connect
    }
  }

  @override
  void dispose() {
    _m3uUrl.dispose();
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    _m3uFocus.dispose();
    _urlFocus.dispose();
    _userFocus.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  bool get _isTextFieldSelected {
    if (_source == _SourceKind.m3u && _selected == 3) return true;
    if (_source == _SourceKind.xtream &&
        (_selected == 3 || _selected == 4 || _selected == 5)) {
      return true;
    }
    return false;
  }

  void _setSource(_SourceKind kind) {
    setState(() {
      _source = kind;
      _localError = null;
      // Land on first field of that section (or stay on chooser if none).
      _selected = kind == _SourceKind.none ? _selected.clamp(0, 2) : 3;
    });
    _syncFieldFocus();
  }

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      void clear() {
        _m3uFocus.unfocus();
        _urlFocus.unfocus();
        _userFocus.unfocus();
        _passFocus.unfocus();
        FocusManager.instance.primaryFocus?.unfocus();
      }

      if (_source == _SourceKind.m3u && _selected == 3) {
        _m3uFocus.requestFocus();
        return;
      }
      if (_source == _SourceKind.xtream) {
        switch (_selected) {
          case 3:
            _urlFocus.requestFocus();
            return;
          case 4:
            _userFocus.requestFocus();
            return;
          case 5:
            _passFocus.requestFocus();
            return;
        }
      }
      clear();
    });
  }

  Future<void> _activate() async {
    switch (_selected) {
      case 0:
        await _demo();
      case 1:
        _setSource(_SourceKind.m3u);
      case 2:
        _setSource(_SourceKind.xtream);
      default:
        if (_source == _SourceKind.m3u) {
          if (_selected == 3) {
            _nav(1); // url → open
          } else if (_selected == 4) {
            await _loadM3u();
          }
        } else if (_source == _SourceKind.xtream) {
          if (_selected == 3 || _selected == 4) {
            _nav(1);
          } else if (_selected == 5 || _selected == 6) {
            await _connect();
          }
        }
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

  Future<void> _loadM3u() async {
    final url = _m3uUrl.text.trim();
    if (url.isEmpty) {
      setState(
        () => _localError =
            'Paste an http(s) M3U playlist URL (public/legal lists only).',
      );
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      setState(
        () => _localError = 'M3U URL must start with http:// or https://',
      );
      return;
    }
    setState(() {
      _busy = true;
      _localError = null;
    });
    await widget.session.connectM3u(url);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _connect() async {
    final url = _url.text.trim();
    final user = _user.text.trim();
    final pass = _pass.text;
    if (url.isEmpty || user.isEmpty || pass.isEmpty) {
      setState(
        () => _localError =
            'Enter server URL, username, and password — or Demo / M3U.',
      );
      return;
    }
    if (!XtreamCredentials.isPlausibleServerUrl(url)) {
      setState(
        () => _localError =
            'Server URL must be like http://host:8080. Or use Demo / M3U.',
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
                              'You supply legal playlists or credentials. '
                              'Pick Demo, or choose M3U / Xtream below.',
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
                              'OR LOAD CHANNELS FROM',
                              style: theme.textTheme.labelSmall?.copyWith(
                                letterSpacing: 1.2,
                                color: theme.colorScheme.outline,
                              ),
                            ),
                            const SizedBox(height: 12),
                            // Two source choosers — only one form expands under them.
                            Row(
                              children: [
                                Expanded(
                                  child: _SelectTile(
                                    selected: _selected == 1,
                                    active: _source == _SourceKind.m3u,
                                    label: 'M3U',
                                    icon: Icons.playlist_play,
                                    compact: true,
                                    onTap: () {
                                      setState(() => _selected = 1);
                                      _setSource(_SourceKind.m3u);
                                    },
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _SelectTile(
                                    selected: _selected == 2,
                                    active: _source == _SourceKind.xtream,
                                    label: 'Xtream',
                                    icon: Icons.cloud_outlined,
                                    compact: true,
                                    onTap: () {
                                      setState(() => _selected = 2);
                                      _setSource(_SourceKind.xtream);
                                    },
                                  ),
                                ),
                              ],
                            ),
                            if (_source == _SourceKind.none) ...[
                              const SizedBox(height: 16),
                              Text(
                                'A on M3U or Xtream to continue',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.outline,
                                ),
                              ),
                            ],
                            if (_source == _SourceKind.m3u) ...[
                              const SizedBox(height: 20),
                              Text(
                                'M3U playlist',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 12),
                              _SelectField(
                                selected: _selected == 3,
                                label: 'Playlist URL (http… .m3u)',
                                controller: _m3uUrl,
                                focusNode: _m3uFocus,
                                keyboardType: TextInputType.url,
                                onTap: () {
                                  setState(() => _selected = 3);
                                  _syncFieldFocus();
                                },
                              ),
                              const SizedBox(height: 12),
                              _SelectTile(
                                selected: _selected == 4,
                                label: _busy
                                    ? 'Loading M3U…'
                                    : 'Open M3U playlist',
                                icon: Icons.login,
                                onTap: () {
                                  setState(() => _selected = 4);
                                  if (!_busy) _loadM3u();
                                },
                              ),
                            ],
                            if (_source == _SourceKind.xtream) ...[
                              const SizedBox(height: 20),
                              Text(
                                'Xtream Codes',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 12),
                              _SelectField(
                                selected: _selected == 3,
                                label: 'Server URL (http://host:port)',
                                controller: _url,
                                focusNode: _urlFocus,
                                keyboardType: TextInputType.url,
                                onTap: () {
                                  setState(() => _selected = 3);
                                  _syncFieldFocus();
                                },
                              ),
                              const SizedBox(height: 12),
                              _SelectField(
                                selected: _selected == 4,
                                label: 'Username',
                                controller: _user,
                                focusNode: _userFocus,
                                onTap: () {
                                  setState(() => _selected = 4);
                                  _syncFieldFocus();
                                },
                              ),
                              const SizedBox(height: 12),
                              _SelectField(
                                selected: _selected == 5,
                                label: 'Password',
                                controller: _pass,
                                focusNode: _passFocus,
                                obscureText: !_showPassword,
                                textInputAction: TextInputAction.done,
                                onSubmitted: _busy ? null : _connect,
                                onTap: () {
                                  setState(() => _selected = 5);
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
                                    setState(
                                      () => _showPassword = !_showPassword,
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 20),
                              _SelectTile(
                                selected: _selected == 6,
                                label: _busy
                                    ? 'Connecting…'
                                    : 'Connect to provider',
                                icon: Icons.login,
                                onTap: () {
                                  setState(() => _selected = 6);
                                  if (!_busy) _connect();
                                },
                              ),
                            ],
                            if (err != null) ...[
                              const SizedBox(height: 20),
                              Text(
                                err,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ],
                            if (_isTextFieldSelected) ...[
                              const SizedBox(height: 16),
                              Text(
                                _source == _SourceKind.xtream && _selected == 5
                                    ? 'Type with OSK · eye icon shows password · A = connect'
                                    : 'Type with OSK · D-pad moves · A confirms',
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
    this.active = false,
    this.compact = false,
  });

  final bool selected;
  final bool active;
  final bool compact;
  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Focus ring uses primary; "active source" keeps a soft primary tint when
    // focus moves into the form below.
    final bg = selected
        ? theme.colorScheme.primary
        : active
            ? theme.colorScheme.primary.withValues(alpha: 0.22)
            : theme.colorScheme.surfaceContainerHighest;
    final fg = selected
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 14 : 20,
          vertical: compact ? 18 : 16,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primaryContainer
                : active
                    ? theme.colorScheme.primary.withValues(alpha: 0.55)
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
          mainAxisAlignment:
              compact ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: [
            if (icon != null) ...[
              Icon(icon, color: fg, size: compact ? 26 : 28),
              SizedBox(width: compact ? 8 : 12),
            ],
            Flexible(
              child: Text(
                label,
                textAlign: compact ? TextAlign.center : TextAlign.start,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: fg,
                  fontWeight:
                      selected || active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            if (active && !selected) ...[
              const SizedBox(width: 6),
              Icon(Icons.check_circle, color: fg, size: 20),
            ],
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
          onTap: onTap,
          onSubmitted: (_) => onSubmitted?.call(),
        ),
      ),
    );
  }
}
