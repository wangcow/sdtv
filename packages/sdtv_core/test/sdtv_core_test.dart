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

    test('lists VOD categories and movies', () async {
      final fixtureDir = Directory(
        '${Directory.current.path}/../../tool/mock_xtream/fixtures',
      );
      final client = MockXtreamClient(
        authJson: authJson,
        liveCategoriesJson: categoriesJson,
        liveStreamsJson: streamsJson,
        vodCategoriesJson:
            File('${fixtureDir.path}/vod_categories.json').readAsStringSync(),
        vodStreamsJson:
            File('${fixtureDir.path}/vod_streams.json').readAsStringSync(),
      );
      final cats = await client.getVodCategories();
      expect(cats.map((c) => c.categoryName), contains('Action'));
      final action = await client.getVodStreams(categoryId: '10');
      expect(action, hasLength(2));
      expect(action.first.name, 'Demo Feature');
    });

    test('getVodInfo reads fixture metadata', () async {
      final fixtureDir = Directory(
        '${Directory.current.path}/../../tool/mock_xtream/fixtures',
      );
      final client = MockXtreamClient(
        authJson: authJson,
        liveCategoriesJson: categoriesJson,
        liveStreamsJson: streamsJson,
        vodStreamsJson:
            File('${fixtureDir.path}/vod_streams.json').readAsStringSync(),
        vodInfoJson:
            File('${fixtureDir.path}/vod_info.json').readAsStringSync(),
      );
      final info = await client.getVodInfo(9001);
      expect(info.title, 'Demo Feature');
      expect(info.director, 'Ada Mock');
      expect(info.cast, contains('Jordan Example'));
      expect(info.hasTrailer, isTrue);
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
      expect(
        creds.movieStreamUri(9, extension: 'mkv').toString(),
        'http://example.com:8080/movie/u/secret/9.mkv',
      );
      expect(
        creds.seriesStreamUri('8101', extension: 'mp4').toString(),
        'http://example.com:8080/series/u/secret/8101.mp4',
      );
    });

    test('lists series categories, shows, and getSeriesInfo', () async {
      final fixtureDir = Directory(
        '${Directory.current.path}/../../tool/mock_xtream/fixtures',
      );
      final client = MockXtreamClient(
        authJson: authJson,
        liveCategoriesJson: categoriesJson,
        liveStreamsJson: streamsJson,
        seriesCategoriesJson:
            File('${fixtureDir.path}/series_categories.json').readAsStringSync(),
        seriesJson: File('${fixtureDir.path}/series.json').readAsStringSync(),
        seriesInfoJson:
            File('${fixtureDir.path}/series_info.json').readAsStringSync(),
      );
      final cats = await client.getSeriesCategories();
      expect(cats.map((c) => c.categoryName), contains('Drama'));
      final drama = await client.getSeries(categoryId: '20');
      expect(drama, hasLength(1));
      expect(drama.single.name, 'Harbor Nights');
      final info = await client.getSeriesInfo(8001);
      expect(info.info.title, 'Harbor Nights');
      expect(info.seasons, hasLength(2));
      expect(info.firstEpisode?.title, 'Pilot');
      expect(info.episodeById('8201')?.title, 'Low Tide');
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
      expect(ch.favoriteKey, 'i:99');
    });

    test('LiveChannel favoriteKey prefers stream URL for M3U', () {
      const ch = LiveChannel(
        streamId: 1,
        name: 'News',
        categoryId: 'g1',
        streamUrl: 'https://example.com/live.ts',
      );
      expect(ch.favoriteKey, 'u:https://example.com/live.ts');
    });

    test('LiveChannel favoriteKey avoids i:0 collisions', () {
      const a = LiveChannel(
        streamId: 0,
        name: 'Forensic Files',
        categoryId: 'doc',
      );
      const b = LiveChannel(
        streamId: 0,
        name: 'Other Show',
        categoryId: 'doc',
      );
      expect(a.favoriteKey, isNot(b.favoriteKey));
      expect(a.favoriteKey, startsWith('n:'));
    });
  });
}
