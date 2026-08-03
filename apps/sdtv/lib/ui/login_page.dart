import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sdtv_core/sdtv_core.dart';
import 'package:sdtv_input/sdtv_input.dart';

import '../state/session_controller.dart';
import 'widgets/focus_text_field.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.session});

  final SessionController session;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();

  final _demoFocus = FocusNode(debugLabel: 'demo');
  final _urlFocus = FocusNode(debugLabel: 'url');
  final _userFocus = FocusNode(debugLabel: 'user');
  final _passFocus = FocusNode(debugLabel: 'pass');
  final _connectFocus = FocusNode(debugLabel: 'connect');

  late final List<FocusNode> _ring;
  int _index = 0;

  /// Deck/Steam often emit *both* js D-pad and keyboard arrows for one press.
  DateTime? _lastNavAt;
  static const _navCooldown = Duration(milliseconds: 180);

  bool _busy = false;
  String? _localError;

  @override
  void initState() {
    super.initState();
    _ring = [_demoFocus, _urlFocus, _userFocus, _passFocus, _connectFocus];
    for (var i = 0; i < _ring.length; i++) {
      final idx = i;
      _ring[i].addListener(() {
        if (_ring[idx].hasFocus && _index != idx) {
          setState(() => _index = idx);
        }
      });
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    for (final n in _ring) {
      n.dispose();
    }
    super.dispose();
  }

  bool _acceptNav() {
    final now = DateTime.now();
    if (_lastNavAt != null && now.difference(_lastNavAt!) < _navCooldown) {
      return false;
    }
    _lastNavAt = now;
    return true;
  }

  void _move(int delta) {
    if (!_acceptNav()) return;
    if (_ring.isEmpty) return;
    _index = (_index + delta).clamp(0, _ring.length - 1);
    _ring[_index].requestFocus();
    setState(() {});
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
    final sessionError = widget.session.errorMessage;
    final err = _localError ?? sessionError;

    return SdtvInputScope(
      onConfirm: () {
        // Activate current ring item.
        switch (_index) {
          case 0:
            if (!_busy) _demo();
          case 1:
          case 2:
            _move(1); // leave field → next
          case 3:
            if (!_busy) _connect();
          case 4:
            if (!_busy) _connect();
        }
      },
      extraActions: {
        DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
          onInvoke: (intent) {
            final forward = intent.direction == TraversalDirection.down ||
                intent.direction == TraversalDirection.right;
            _move(forward ? 1 : -1);
            return null;
          },
        ),
        NextFocusIntent: CallbackAction<NextFocusIntent>(
          onInvoke: (_) {
            _move(1);
            return null;
          },
        ),
        PreviousFocusIntent: CallbackAction<PreviousFocusIntent>(
          onInvoke: (_) {
            _move(-1);
            return null;
          },
        ),
      },
      // Kill default arrow shortcuts that would *also* fire DirectionalFocus
      // after our action (Steam often injects arrows for D-pad).
      extraShortcuts: const {},
      child: Shortcuts(
        // Replace arrow keys with our ring moves only (no double-fire via
        // both Shortcuts→DirectionalFocus and gamepad→DirectionalFocus without
        // sharing cooldown — cooldown is in _move).
        shortcuts: {
          const SingleActivator(LogicalKeyboardKey.arrowDown):
              const _LoginMoveIntent(1),
          const SingleActivator(LogicalKeyboardKey.arrowRight):
              const _LoginMoveIntent(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp):
              const _LoginMoveIntent(-1),
          const SingleActivator(LogicalKeyboardKey.arrowLeft):
              const _LoginMoveIntent(-1),
          const SingleActivator(LogicalKeyboardKey.tab):
              const _LoginMoveIntent(1),
          const SingleActivator(LogicalKeyboardKey.tab, shift: true):
              const _LoginMoveIntent(-1),
        },
        child: Actions(
          actions: {
            _LoginMoveIntent: CallbackAction<_LoginMoveIntent>(
              onInvoke: (intent) {
                _move(intent.delta);
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
                              'Demo mode uses local mock data (no network).',
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 28),
                            SdtvFocusTile(
                              label: 'Continue with demo playlist',
                              icon: Icons.play_circle_outline,
                              focusNode: _demoFocus,
                              autofocus: true,
                              onActivate: _busy ? null : _demo,
                            ),
                            const SizedBox(height: 28),
                            Text(
                              'OR ADD YOUR PLAYLIST',
                              style: theme.textTheme.labelSmall?.copyWith(
                                letterSpacing: 1.2,
                                color: theme.colorScheme.outline,
                              ),
                            ),
                            const SizedBox(height: 12),
                            // Fields: no arrow handling of their own — parent ring owns nav.
                            SdtvFocusTextField(
                              controller: _url,
                              focusNode: _urlFocus,
                              label: 'Server URL (http://host:port)',
                              keyboardType: TextInputType.url,
                              handleArrowKeys: false,
                            ),
                            const SizedBox(height: 12),
                            SdtvFocusTextField(
                              controller: _user,
                              focusNode: _userFocus,
                              label: 'Username',
                              handleArrowKeys: false,
                            ),
                            const SizedBox(height: 12),
                            SdtvFocusTextField(
                              controller: _pass,
                              focusNode: _passFocus,
                              label: 'Password',
                              obscureText: true,
                              textInputAction: TextInputAction.done,
                              handleArrowKeys: false,
                              onSubmitted: _busy ? null : _connect,
                            ),
                            const SizedBox(height: 20),
                            SdtvFocusTile(
                              label: _busy ? 'Connecting…' : 'Connect',
                              icon: Icons.login,
                              focusNode: _connectFocus,
                              onActivate: _busy ? null : _connect,
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

class _LoginMoveIntent extends Intent {
  const _LoginMoveIntent(this.delta);
  final int delta;
}
