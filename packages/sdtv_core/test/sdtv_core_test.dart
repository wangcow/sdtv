import 'dart:io';

import 'package:sdtv_core/sdtv_core.dart';
import 'package:test/test.dart';

void main() {
  late String authJson;
  late String categoriesJson;
  late String streamsJson;

  setUpAll(() {
    // Resolve fixtures relative to monorepo root or package cwd.
    final candidates = [
      Directory.current.path,
      Directory.current.parent.path,
      Directory.current.parent.parent.path,
    ];
    Directory? root;
    for (final c in candidates) {
      final dir = Directory('$c/tool/mock_xtream/fixtures');
      if (dir.existsSync()) {
        root = Directory(c);
        break;
      }
      final dir2 = Directory('$c/../tool/mock_xtream/fixtures');
      if (dir2.existsSync()) {
        root = Directory('$c/..').absolute;
        break;
      }
    }
    // packages/sdtv_core -> repo root is ../..
    final fromPackage = Directory(
      '${Directory.current.path}/../../tool/mock_xtream/fixtures',
    );
    final fixtureDir = fromPackage.existsSync()
        ? fromPackage
        : Directory('${root!.path}/tool/mock_xtream/fixtures');

    authJson = File('${fixtureDir.path}/auth_ok.json').readAsStringSync();
    categoriesJson =
        File('${fixtureDir.path}/live_categories.json').readAsStringSync();
    streamsJson =
        File('${fixtureDir.path}/live_streams.json').readAsStringSync();
  });

  group('MockXtreamClient', () {
    test('authenticates from fixture', () async {
      final client = MockXtreamClient(
        authJson: authJson,
        liveCategoriesJson: categoriesJson,
        liveStreamsJson: streamsJson,
      );
      final info = await client.authenticate();
      expect(info.username, 'mock_user');
      expect(info.isActive, isTrue);
    });

    test('lists live categories', () async {
      final client = MockXtreamClient(
        authJson: authJson,
        liveCategoriesJson: categoriesJson,
        liveStreamsJson: streamsJson,
      );
      final cats = await client.getLiveCategories();
      expect(cats, hasLength(3));
      expect(cats.map((c) => c.categoryName), contains('Sports'));
    });

    test('filters live streams by category', () async {
      final client = MockXtreamClient(
        authJson: authJson,
        liveCategoriesJson: categoriesJson,
        liveStreamsJson: streamsJson,
      );
      final sports = await client.getLiveStreams(categoryId: '3');
      expect(sports, hasLength(1));
      expect(sports.single.name, 'Mock Sports HD');
    });

    test('builds live play URL without exposing secrets in toString of creds',
        () {
      final creds = XtreamCredentials(
        baseUrl: 'http://example.com:8080',
        username: 'u',
        password: 'secret',
      );
      expect(creds.toString(), isNot(contains('secret')));
      expect(
        creds.liveStreamUri(42).toString(),
        'http://example.com:8080/live/u/secret/42.ts',
      );
    });
  });

  group('models', () {
    test('LiveChannel parses stringy ids', () {
      final ch = LiveChannel.fromJson({
        'stream_id': '99',
        'name': 'Test',
        'category_id': 1,
        'num': '5',
      });
      expect(ch.streamId, 99);
      expect(ch.categoryId, '1');
      expect(ch.num, 5);
    });
  });
}
