import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sdtv_player/sdtv_player.dart';

import 'app.dart';
import 'services/settings_store.dart';
import 'state/session_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final settings = await SettingsStore.open();
  final session = SessionController(
    settings: settings,
    player: MediaKitSdtvPlayerController(),
  );
  runApp(SdtvApp(session: session));
}
