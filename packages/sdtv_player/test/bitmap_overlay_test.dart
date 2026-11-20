import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_player/src/bitmap_overlay.dart';

void main() {
  test('premultiplied rgba swaps to bgra without re-multiplying', () {
    final rgba = Uint8List.fromList([
      128, 0, 0, 128, // semi red, already premultiplied
      0, 0, 0, 0, // hole
      10, 20, 30, 255, // opaque
      0, 64, 32, 64, // semi teal
    ]);
    final out = rgbaPremulToBgraInPlace(rgba);
    expect(identical(out, rgba), isTrue);
    expect(out.sublist(0, 4), [0, 0, 128, 128]);
    expect(out.sublist(4, 8), [0, 0, 0, 0]);
    expect(out.sublist(8, 12), [30, 20, 10, 255]);
    expect(out.sublist(12, 16), [32, 64, 0, 64]);
  });

  test('unaligned views fall back to the byte loop', () {
    final backing = Uint8List.fromList([9, 1, 2, 3, 4, 0]);
    final view = Uint8List.sublistView(backing, 1, 5);
    expect(rgbaPremulToBgraInPlace(view), [3, 2, 1, 4]);
  });

  test('overlay-add carries the band position', () {
    expect(
      bitmapOverlayAddCommand(
        id: 3,
        file: '/tmp/hud.bgra',
        width: 8,
        height: 4,
        x: 0,
        y: 700,
      ).sublist(0, 4),
      ['overlay-add', 3, 0, 700],
    );
  });

  test('overlay-add command is positional bgra', () {
    expect(
      bitmapOverlayAddCommand(
        id: 2,
        file: '/tmp/hud.bgra',
        width: 32,
        height: 16,
      ),
      ['overlay-add', 2, 0, 0, '/tmp/hud.bgra', 0, 'bgra', 32, 16, 128],
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
