import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_player/sdtv_player.dart';

void main() {
  test('play log keeps the host but drops credentials in stream URLs', () {
    final line = ExternalMpvLauncher.redactUrls(
      '[ffmpeg] http: HTTP error 403 for http://panel.example:8080/live/alice/s3cret/101.ts',
    );
    expect(line, contains('http://panel.example:8080/…'));
    expect(line, isNot(contains('alice')));
    expect(line, isNot(contains('s3cret')));
    expect(line, startsWith('[ffmpeg] http: HTTP error 403 for'));
  });
}
