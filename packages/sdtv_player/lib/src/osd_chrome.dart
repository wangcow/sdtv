// ASS + plain OSD helpers for mpv (video plane, 60fps).
// Stock OSC is off for live. This is the couch HUD — not Flutter texture chrome.

String assEscape(String raw) {
  return raw
      .replaceAll('\\', '\\\\')
      .replaceAll('{', '(')
      .replaceAll('}', ')')
      .replaceAll('\r', '');
}

/// Block progress bar for ASS / show-text (no OSC seek bar).
String osdProgressBar(double t, {int width = 28}) {
  final n = width.clamp(8, 48);
  final filled = (t.clamp(0.0, 1.0) * n).round().clamp(0, n);
  return '${'█' * filled}${'░' * (n - filled)}';
}

String osdFmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (h > 0) return '$h:$m:$s';
  return '$m:$s';
}

/// Bottom HUD: LIVE badge, title, now/next, hint (Flutter-chrome layout).
String liveBannerAss({
  required String title,
  String? nowLine,
  String? nextLine,
  String hint = 'A menu  ·  B guide  ·  LB/RB channel',
}) {
  final buf = StringBuffer(
    r'{\an2\bord3\shad1\3c&H000000&\c&HCECEFF&\fs30\b1}● LIVE',
  );
  buf.write(r'\N{\fs46\b1\c&HFFFFFF&}');
  buf.write(assEscape(title));
  if (nowLine != null && nowLine.trim().isNotEmpty) {
    buf.write(r'\N{\fs32\b0\c&HFFFFFF&\alpha&H00&}');
    buf.write(assEscape(nowLine.trim()));
  }
  if (nextLine != null && nextLine.trim().isNotEmpty) {
    buf.write(r'\N{\fs28\b0\c&HFFFFFF&\alpha&H40&}');
    buf.write(assEscape(nextLine.trim()));
  }
  buf.write(r'\N{\fs22\b0\c&HFFFFFF&\alpha&H50&}');
  buf.write(assEscape(hint));
  return buf.toString();
}

String liveBannerPlain({
  required String title,
  String? nowLine,
  String? nextLine,
  String hint = 'A menu  ·  B guide  ·  LB/RB channel',
}) {
  final buf = StringBuffer('● LIVE\n');
  buf.writeln(title);
  if (nowLine != null && nowLine.trim().isNotEmpty) {
    buf.writeln(nowLine.trim());
  }
  if (nextLine != null && nextLine.trim().isNotEmpty) {
    buf.writeln(nextLine.trim());
  }
  buf.write(hint);
  return buf.toString();
}

/// VOD seek / playing HUD: title, time, bar, hint.
String vodHudAss({
  required String title,
  required String timeLine,
  double progress = 0,
  String hint = '←→ seek 10s  ·  A menu  ·  B back',
}) {
  final buf = StringBuffer(
    r'{\an2\bord3\shad1\3c&H000000&\c&HFFFFFF&\fs42\b1}',
  );
  buf.write(assEscape(title));
  buf.write(r'\N{\fs30\b0}');
  buf.write(assEscape(timeLine));
  buf.write(r'\N{\fs36\b0\c&H7ADFFF&}');
  buf.write(osdProgressBar(progress));
  buf.write(r'\N{\fs22\b0\c&HFFFFFF&\alpha&H50&}');
  buf.write(assEscape(hint));
  return buf.toString();
}

String vodHudPlain({
  required String title,
  required String timeLine,
  double progress = 0,
  String hint = '←→ seek 10s  ·  A menu  ·  B back',
}) {
  return '$title\n$timeLine\n${osdProgressBar(progress)}\n$hint';
}

/// Pause menu: title + optional time/bar + cursor rows (centered card).
String watchMenuAss({
  required String title,
  required List<String> rows,
  required int selected,
  String? timeLine,
  double? progress,
  bool live = false,
  String hint = '↑↓ move  ·  A select  ·  B close',
}) {
  final buf = StringBuffer(
    r'{\an5\bord3\shad1\3c&H000000&\c&HFFFFFF&\fs40\b1}',
  );
  if (live) {
    buf.write(r'{\fs28\c&HCECEFF&}● LIVE\N{\fs40\c&HFFFFFF&}');
  } else {
    buf.write(r'❚❚  ');
  }
  buf.write(assEscape(title));
  if (timeLine != null && timeLine.trim().isNotEmpty) {
    buf.write(r'\N{\fs28\b0}');
    buf.write(assEscape(timeLine.trim()));
  }
  if (progress != null) {
    buf.write(r'\N{\fs32\b0\c&H7ADFFF&}');
    buf.write(osdProgressBar(progress));
  }
  buf.write(r'\N{\fs32\b0\c&HFFFFFF&}');
  for (var i = 0; i < rows.length; i++) {
    final mark = i == selected ? '▶  ' : '    ';
    buf.write(r'\N');
    if (i == selected) {
      buf.write(r'{\b1\c&H7ADFFF&}');
    } else {
      buf.write(r'{\b0\c&HFFFFFF&}');
    }
    buf.write(assEscape('$mark${rows[i]}'));
  }
  buf.write(r'\N{\fs22\b0\c&HFFFFFF&\alpha&H40&}');
  buf.write(r'\N');
  buf.write(assEscape(hint));
  return buf.toString();
}

String watchMenuPlain({
  required String title,
  required List<String> rows,
  required int selected,
  String? timeLine,
  double? progress,
  bool live = false,
  String hint = '↑↓ move  ·  A select  ·  B close',
}) {
  final buf = StringBuffer(live ? '● LIVE\n$title\n' : '❚❚  $title\n');
  if (timeLine != null && timeLine.trim().isNotEmpty) {
    buf.writeln(timeLine.trim());
  }
  if (progress != null) {
    buf.writeln(osdProgressBar(progress));
  }
  buf.writeln('────────────────');
  for (var i = 0; i < rows.length; i++) {
    final mark = i == selected ? '▶ ' : '   ';
    buf.writeln('$mark${rows[i]}');
  }
  buf.write(hint);
  return buf.toString();
}
