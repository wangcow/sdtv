import 'dart:io';

/// Open a URL in the system browser / YouTube (TiviMate-style trailer).
///
/// Steam Deck Game Mode: try `xdg-open`, then Steam's external-url helper.
Future<bool> openExternalUrl(Uri uri) async {
  final url = uri.toString();
  if (url.isEmpty) return false;
  final attempts = <List<String>>[
    ['xdg-open', url],
    ['gio', 'open', url],
    ['steam', 'steam://openurl_external/$url'],
  ];
  for (final cmd in attempts) {
    try {
      await Process.start(
        cmd.first,
        cmd.sublist(1),
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (_) {}
  }
  return false;
}
