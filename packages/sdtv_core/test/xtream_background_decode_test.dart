import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sdtv_core/sdtv_core.dart';
import 'package:test/test.dart';

HttpXtreamClient _client(http.Response Function(http.Request) reply) =>
    HttpXtreamClient(
      credentials: XtreamCredentials(
        baseUrl: 'http://panel.example:8080',
        username: 'u',
        password: 'p',
      ),
      httpClient: MockClient((req) async => reply(req)),
    );

http.Response _bytes(String body, String contentType) => http.Response.bytes(
  utf8.encode(body),
  200,
  headers: {'content-type': contentType},
);

void main() {
  test('big lists decode in the background, UTF-8 for JSON', () async {
    final list = [
      for (var i = 0; i < 5000; i++)
        {'stream_id': i + 1, 'name': 'Café $i', 'category_id': '1', 'num': i},
    ];
    final client = _client((_) => _bytes(jsonEncode(list), 'application/json'));
    final channels = await client.getLiveStreams();
    expect(channels, hasLength(5000));
    expect(channels.first.name, 'Café 0');
    expect(channels.last.streamId, 5000);
  });

  test(
    'text decoding matches http Response.body for other content types',
    () async {
      const body = '[{"stream_id":1,"name":"Café","category_id":"1"}]';
      final client = _client((_) => _bytes(body, 'text/html'));
      final vod = await client.getVodStreams();
      // Same result the old main-thread path gave (Response.body's charset rules).
      final expected = _bytes(body, 'text/html').body;
      expect(vod.single.name, (jsonDecode(expected) as List).first['name']);
    },
  );

  test(
    'an HTML login error on a list call still gives the login hint',
    () async {
      final client = _client(
        (_) => _bytes(
          '<html><title>INVALID_CREDENTIALS</title></html>',
          'text/html',
        ),
      );
      expect(
        client.getSeries(),
        throwsA(
          isA<XtreamException>().having(
            (e) => e.message,
            'message',
            contains('Username or password is invalid'),
          ),
        ),
      );
    },
  );
}
