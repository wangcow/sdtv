import 'package:flutter/material.dart';

import 'state/session_controller.dart';
import 'theme.dart';
import 'ui/live_browse_page.dart';
import 'ui/login_page.dart';

class SdtvApp extends StatefulWidget {
  const SdtvApp({super.key, required this.session});

  final SessionController session;

  @override
  State<SdtvApp> createState() => _SdtvAppState();
}

class _SdtvAppState extends State<SdtvApp> {
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSession);
    widget.session.bootstrap();
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sdtv',
      debugShowCheckedModeBanner: false,
      theme: sdtvDarkTheme,
      home: _home(),
    );
  }

  Widget _home() {
    final session = widget.session;
    switch (session.phase) {
      case SessionPhase.boot:
      case SessionPhase.loading:
        return const _BootSplash();
      case SessionPhase.login:
      case SessionPhase.error:
        return LoginPage(session: session);
      case SessionPhase.browse:
        return LiveBrowsePage(session: session);
    }
  }
}

class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'sdtv',
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 24),
            const SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
          ],
        ),
      ),
    );
  }
}
