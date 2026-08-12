// ASS helpers for mpv osd-overlay (drawn on the video plane — 60fps).
// Stock OSC is the seek bar; we keep that off for live. This is the couch
// banner / pause menu, not Flutter texture chrome.

String assEscape(String raw) {
  return raw
      .replaceAll('\\', '\\\\')
      .replaceAll('{', '(')
      .replaceAll('}', ')')
      .replaceAll('\r', '');
}

/// Bottom-aligned live banner (channel + now/next + hint).
String liveBannerAss({
  required String title,
  String? nowLine,
  String? nextLine,
  String hint = 'A menu  ·  B guide  ·  LB/RB channel',
}) {
  final buf = StringBuffer(
    r'{\an2\bord3\shad0\3c&H000000&\c&HFFFFFF&\fs46\b1}',
  );
  buf.write(assEscape(title));
  buf.write(r'\N');
  if (nowLine != null && nowLine.trim().isNotEmpty) {
    buf.write(r'{\fs32\b0}');
    buf.write(assEscape(nowLine.trim()));
    buf.write(r'\N');
  }
  if (nextLine != null && nextLine.trim().isNotEmpty) {
    buf.write(r'{\fs28\b0\alpha&H33&}');
    buf.write(assEscape(nextLine.trim()));
    buf.write(r'\N');
  }
  buf.write(r'{\fs24\b0\alpha&H40&}');
  buf.write(assEscape(hint));
  return buf.toString();
}

/// Pause menu: title + numbered rows with a cursor.
String watchMenuAss({
  required String title,
  required List<String> rows,
  required int selected,
  String hint = '↑↓ move  ·  ←→ change  ·  A select  ·  B close',
}) {
  final buf = StringBuffer(
    r'{\an5\bord3\shad0\3c&H000000&\c&HFFFFFF&\fs42\b1}',
  );
  buf.write(r'❚❚  ');
  buf.write(assEscape(title));
  buf.write(r'\N{\fs34\b0}');
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
  buf.write(r'\N{\fs24\b0\c&HFFFFFF&\alpha&H40&}');
  buf.write(r'\N');
  buf.write(assEscape(hint));
  return buf.toString();
}
