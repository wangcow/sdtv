import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_player/src/bitmap_overlay.dart';

void main() {
  test('straight rgba becomes premultiplied bgra', () {
    final rgba = Uint8List.fromList([
      255, 0, 0, 128, // semi red
      0, 0, 0, 0, // hole
      10, 20, 30, 255, // opaque
    ]);
    final out = rgbaStraightToBgraPremul(rgba);
    expect(out.sublist(0, 4), [0, 0, 128, 128]);
    expect(out.sublist(4, 8), [0, 0, 0, 0]);
    expect(out.sublist(8, 12), [30, 20, 10, 255]);
  });

  test('overlay-add command is positional bgra', () {
    expect(
      bitmapOverlayAddCommand(
        id: 2,
        file: '/tmp/hud.bgra',
        width: 32,
        height: 16,
      ),
      [
        'overlay-add',
        2,
        0,
        0,
        '/tmp/hud.bgra',
        0,
        'bgra',
        32,
        16,
        128,
      ],
    );
  });

  test('display size is appended only when it differs', () {
    final same = bitmapOverlayAddCommand(
      id: 2,
      file: '/tmp/hud.bgra',
      width: 32,
      height: 16,
      displayWidth: 32,
      displayHeight: 16,
    );
    expect(same, hasLength(10));

    final scaled = bitmapOverlayAddCommand(
      id: 2,
      file: '/tmp/hud.bgra',
      width: 32,
      height: 16,
      displayWidth: 320,
      displayHeight: 180,
    );
    expect(scaled.sublist(10), [320, 180]);
  });
}
