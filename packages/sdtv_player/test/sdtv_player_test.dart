import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_player/sdtv_player.dart';

void main() {
  test('stub player transitions open → playing', () async {
    final player = StubSdtvPlayerController();
    expect(player.state, SdtvPlayerState.idle);
    await player.open(Uri.parse('http://mock.sdtv.local/live/u/p/1.ts'));
    expect(player.state, SdtvPlayerState.playing);
    expect(player.currentUrl, contains('live'));
    await player.pause();
    expect(player.state, SdtvPlayerState.paused);
    await player.dispose();
  });
}
