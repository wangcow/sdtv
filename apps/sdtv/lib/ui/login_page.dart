import 'package:flutter/material.dart';
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
  final _urlFocus = FocusNode(debugLabel: 'url');
  final _userFocus = FocusNode(debugLabel: 'user');
  final _passFocus = FocusNode(debugLabel: 'pass');
  bool _busy = false;
  String? _localError;

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

    return SdtvLoginFormScope(
      onSubmit: _busy ? null : _connect,
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
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(0),
                          child: SdtvFocusTile(
                            label: 'Continue with demo playlist',
                            icon: Icons.play_circle_outline,
                            autofocus: true,
                            onActivate: _busy ? null : _demo,
                          ),
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
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(1),
                          child: SdtvFocusTextField(
                            controller: _url,
                            focusNode: _urlFocus,
                            label: 'Server URL (http://host:port)',
                            keyboardType: TextInputType.url,
                          ),
                        ),
                        const SizedBox(height: 12),
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(2),
                          child: SdtvFocusTextField(
                            controller: _user,
                            focusNode: _userFocus,
                            label: 'Username',
                          ),
                        ),
                        const SizedBox(height: 12),
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(3),
                          child: SdtvFocusTextField(
                            controller: _pass,
                            focusNode: _passFocus,
                            label: 'Password',
                            obscureText: true,
                            textInputAction: TextInputAction.done,
                            onSubmitted: _busy ? null : _connect,
                          ),
                        ),
                        const SizedBox(height: 20),
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(4),
                          child: SdtvFocusTile(
                            label: _busy ? 'Connecting…' : 'Connect',
                            icon: Icons.login,
                            onActivate: _busy ? null : _connect,
                          ),
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
    );
  }
}
