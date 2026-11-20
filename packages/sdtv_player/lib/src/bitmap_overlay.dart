import 'dart:typed_data';

/// Straight RGBA8 (Flutter `rawRgba`) → premultiplied BGRA8 for mpv `overlay-add`.
///
/// mpv's only bitmap format is `bgra`, and the color channels must already be
/// multiplied by alpha. A zero alpha pixel stays fully transparent so the
/// video shows through.
Uint8List rgbaStraightToBgraPremul(Uint8List rgba) {
  final out = Uint8List(rgba.length);
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    final a = rgba[i + 3];
    if (a == 0) continue;
    if (a == 255) {
      out[i] = rgba[i + 2];
      out[i + 1] = rgba[i + 1];
      out[i + 2] = rgba[i];
      out[i + 3] = 255;
      continue;
    }
    out[i] = (rgba[i + 2] * a + 127) ~/ 255;
    out[i + 1] = (rgba[i + 1] * a + 127) ~/ 255;
    out[i + 2] = (rgba[i] * a + 127) ~/ 255;
    out[i + 3] = a;
  }
  return out;
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
