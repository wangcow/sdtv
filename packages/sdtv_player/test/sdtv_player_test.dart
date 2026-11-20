import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_player/sdtv_player.dart';

void main() {
  test('library exports the launcher and HUD state', () {
    expect(SdtvPlayerState.values, contains(SdtvPlayerState.paused));
    expect(
      ExternalMpvLauncher.bitmapOverlayIdBottom,
      isNot(ExternalMpvLauncher.bitmapOverlayId),
    );
  });
}
