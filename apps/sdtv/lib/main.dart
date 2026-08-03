import 'package:flutter/material.dart';

import 'app.dart';
import 'services/settings_store.dart';
import 'state/session_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await SettingsStore.open();
  final session = SessionController(settings: settings);
  runApp(SdtvApp(session: session));
}
