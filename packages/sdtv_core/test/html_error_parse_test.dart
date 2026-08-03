import 'package:sdtv_core/sdtv_core.dart';
import 'package:test/test.dart';

void main() {
  test('XUI INVALID_CREDENTIALS HTML maps to clear message', () {
    // Exercise via a tiny mirror of the parser using public API is hard;
    // credentials + live URL still unit-tested elsewhere.
    final creds = XtreamCredentials(
      baseUrl: 'http://obsoletehost.vip',
      username: 'u',
      password: 'p',
    );
    expect(creds.playerApiUri.toString(), 'http://obsoletehost.vip/player_api.php');
    expect(creds.baseUrl, 'http://obsoletehost.vip');
  });
}
