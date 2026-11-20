import 'dart:typed_data';

/// Premultiplied RGBA8 (Flutter `ImageByteFormat.rawRgba`) → premultiplied
/// BGRA8 for mpv `overlay-add`, **in place**. Returns [rgba].
///
/// Flutter's `rawRgba` is already premultiplied (its straight-alpha format is
/// `rawStraightRgba`), and mpv's `bgra` wants premultiplied too, so only the
/// red and blue bytes swap. Fully transparent pixels stay zero.
Uint8List rgbaPremulToBgraInPlace(Uint8List rgba) {
  final n = rgba.lengthInBytes & ~3;
  if (Endian.host == Endian.little && rgba.offsetInBytes % 4 == 0) {
    final words = rgba.buffer.asUint32List(rgba.offsetInBytes, n >> 2);
    for (var i = 0; i < words.length; i++) {
      final v = words[i];
      if (v == 0) continue;
      // Little-endian word: A B G R → A R G B.
      words[i] = (v & 0xFF00FF00) | ((v & 0xFF) << 16) | ((v >> 16) & 0xFF);
    }
    return rgba;
  }
  for (var i = 0; i < n; i += 4) {
    final r = rgba[i];
    rgba[i] = rgba[i + 2];
    rgba[i + 2] = r;
  }
  return rgba;
}

/// Positional `overlay-add` argv. mpv 0.41 accepts this form.
///
/// [displayWidth] / [displayHeight] are appended only when the bitmap should
/// be scaled onto a different OSD size (`dw` / `dh`).
List<Object> bitmapOverlayAddCommand({
  required int id,
  required String file,
  required int width,
  required int height,
  int x = 0,
  int y = 0,
  int? displayWidth,
  int? displayHeight,
}) {
  final cmd = <Object>[
    'overlay-add',
    id,
    x,
    y,
    file,
    0,
    'bgra',
    width,
    height,
    width * 4,
  ];
  if (displayWidth != null &&
      displayHeight != null &&
      displayWidth >= 16 &&
      displayHeight >= 16 &&
      (displayWidth != width || displayHeight != height)) {
    cmd
      ..add(displayWidth)
      ..add(displayHeight);
  }
  return cmd;
}
