import 'package:flutter/material.dart';

import 'theme.dart';
import 'ui/controller_playground_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SdtvApp());
}

class SdtvApp extends StatelessWidget {
  const SdtvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sdtv',
      debugShowCheckedModeBanner: false,
      theme: sdtvDarkTheme,
      home: const ControllerPlaygroundPage(),
    );
  }
}
