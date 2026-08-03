import 'package:flutter/material.dart';

/// Dark TV-oriented theme (TiviMate-ish).
ThemeData get sdtvDarkTheme {
  const seed = Color(0xFF3B82F6);
  final base = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: Brightness.dark,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: base.copyWith(
      surface: const Color(0xFF0B0F14),
      surfaceContainerHighest: const Color(0xFF1A2332),
    ),
    scaffoldBackgroundColor: const Color(0xFF0B0F14),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF0B0F14),
      foregroundColor: Colors.white,
      elevation: 0,
    ),
    textTheme: Typography.whiteMountainView.apply(
      bodyColor: const Color(0xFFE8EEF7),
      displayColor: Colors.white,
    ),
  );
}
