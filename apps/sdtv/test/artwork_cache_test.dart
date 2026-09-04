import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv/services/artwork_cache.dart';

void main() {
  test('fileKey is stable and filesystem-safe', () {
    final a = ArtworkCache.fileKey(
      scope: 'xtream:host|user',
      kind: 'vod',
      id: '12345',
      url: 'http://cdn.example/p.jpg',
    );
    final b = ArtworkCache.fileKey(
      scope: 'xtream:host|user',
      kind: 'vod',
      id: '12345',
      url: 'http://cdn.example/p.jpg',
    );
    expect(a, b);
    expect(a, isNot(contains('/')));
    expect(a, startsWith('vod_12345_'));
  });

  test('fileKey changes when url changes', () {
    final a = ArtworkCache.fileKey(
      scope: 's',
      kind: 'vod',
      id: '1',
      url: 'http://a/1.jpg',
    );
    final b = ArtworkCache.fileKey(
      scope: 's',
      kind: 'vod',
      id: '1',
      url: 'http://a/2.jpg',
    );
    expect(a, isNot(b));
  });

  test('getFile writes then hits disk; empty url is null', () async {
    final dir = await Directory.systemTemp.createTemp('sdtv-art-');
    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.headers.contentType = ContentType('image', 'jpeg');
        req.response.add([0xFF, 0xD8, 0xFF, 0xD9]);
        await req.response.close();
      });
      final cache = ArtworkCache(root: dir, maxBytes: 1024 * 1024);
      expect(
        await cache.getFile(scope: 's', kind: 'vod', id: '1', url: ''),
        isNull,
      );
      final url = 'http://127.0.0.1:${server.port}/p.jpg';
      final f1 = await cache.getFile(
        scope: 's',
        kind: 'vod',
        id: '1',
        url: url,
      );
      expect(f1, isNotNull);
      expect(await f1!.length(), greaterThan(0));
      final f2 = await cache.getFile(
        scope: 's',
        kind: 'vod',
        id: '1',
        url: url,
      );
      expect(f2!.path, f1.path);
    } finally {
      await server?.close(force: true);
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  });
}
