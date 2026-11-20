import 'package:sdtv_core/sdtv_core.dart';
import 'package:test/test.dart';

void main() {
  group('UserLibrary', () {
    test('round-trips JSON and ignores junk', () {
      const lib = UserLibrary(
        favorites: ['i:1', 'v:9', 's:8'],
        progressSeconds: {'v:9': 120, 'se:1': 40},
        watchedKeys: ['v:2', 'se:1'],
        seriesResume: {
          '8': {'episodeId': '81', 'season': '1', 'episodeNum': '2'},
        },
      );
      final copy = UserLibrary.fromJson(lib.toJson());
      expect(copy.favorites, lib.favorites);
      expect(copy.progressSeconds, lib.progressSeconds);
      expect(copy.watchedKeys, lib.watchedKeys);
      expect(copy.seriesResume['8']?['episodeId'], '81');
      expect(copy.toJson()['v'], UserLibrary.schemaVersion);
    });

    test('toggle favorite add then remove', () {
      const empty = UserLibrary.empty;
      final added = empty.withFavoriteToggled('v:9');
      expect(added.favorites, ['v:9']);
      expect(added.withFavoriteToggled('v:9').favorites, isEmpty);
    });

    test('progress drops at or below 5 seconds', () {
      final lib = const UserLibrary().withProgress('v:1', 90).withProgress('v:1', 4);
      expect(lib.progressSeconds.containsKey('v:1'), isFalse);
    });

    test('watched is idempotent', () {
      final once = const UserLibrary().withWatched('se:1', atMs: 50);
      expect(once.withWatched('se:1', atMs: 50).watchedKeys, ['se:1']);
      expect(once.withWatched('se:1', atMs: 40).updatedAtMs, 50);
    });

    test('legacy JSON without timestamps still loads', () {
      final lib = UserLibrary.fromJson({
        'v': 1,
        'favorites': ['v:1'],
        'progress': {'se:1': 90},
        'watched': ['v:2'],
        'seriesResume': {
          '8': {'episodeId': '81', 'season': '1', 'episodeNum': '1'},
        },
      });
      expect(lib.progressSeconds['se:1'], 90);
      expect(lib.progressUpdatedAt, isEmpty);
      expect(lib.watchedKeys, ['v:2']);
      expect(lib.watchedAt, isEmpty);
      expect(lib.updatedAtMs, 0);
    });

    test('phone spot and watched titles merge onto the TV copy', () {
      final tv = const UserLibrary()
          .withFavoriteToggled('v:2', atMs: 1000)
          .withWatchUpdate(
            progressKey: 'se:8102',
            positionSeconds: 100,
            seriesId: '8001',
            episodeId: '8101',
            season: 1,
            episodeNum: 1,
            atMs: 1000,
          )
          .withWatchUpdate(
            progressKey: 'v:9',
            positionSeconds: 500,
            atMs: 1000,
          );
      final phone = const UserLibrary()
          .withFavoriteToggled('s:8', atMs: 2000)
          .withWatchUpdate(
            progressKey: 'se:8102',
            positionSeconds: 640,
            seriesId: '8001',
            episodeId: '8102',
            season: 1,
            episodeNum: 2,
            atMs: 2000,
          )
          .withWatchUpdate(
            progressKey: 'v:9',
            positionSeconds: 0,
            finished: true,
            atMs: 2000,
          )
          .withWatched('se:8101', atMs: 1500);

      final merged = tv.merge(phone);
      final roundTrip = UserLibrary.fromJson(merged.toJson());

      expect(roundTrip.progressSeconds['se:8102'], 640);
      expect(roundTrip.seriesResume['8001']?['episodeId'], '8102');
      expect(roundTrip.watchedKeys, contains('v:9'));
      expect(roundTrip.watchedKeys, contains('se:8101'));
      expect(roundTrip.progressSeconds.containsKey('v:9'), isFalse);
      expect(roundTrip.progressUpdatedAt['v:9'], 2000);
      expect(roundTrip.favorites, ['s:8', 'v:2']);
    });

    test('rewatch after finished keeps the new spot and the watched flag', () {
      final finished = const UserLibrary().withWatchUpdate(
        progressKey: 'v:9',
        positionSeconds: 0,
        finished: true,
        atMs: 1000,
      );
      final again = finished.withWatchUpdate(
        progressKey: 'v:9',
        positionSeconds: 40,
        atMs: 3000,
      );
      final otherDevice = const UserLibrary().withWatchUpdate(
        progressKey: 'v:9',
        positionSeconds: 0,
        finished: true,
        atMs: 1000,
      );

      final merged = otherDevice.merge(again);
      expect(merged.watchedKeys, contains('v:9'));
      expect(merged.progressSeconds['v:9'], 40);
    });

    test('same stamp keeps this device series pointer', () {
      final local = const UserLibrary().withSeriesResume(
        seriesId: '8',
        episodeId: '81',
        season: 1,
        episodeNum: 1,
        atMs: 5,
      );
      final remote = const UserLibrary().withSeriesResume(
        seriesId: '8',
        episodeId: '82',
        season: 1,
        episodeNum: 2,
        atMs: 5,
      );
      expect(local.merge(remote).seriesResume['8']?['episodeId'], '81');
    });

    test('key kind helpers', () {
      expect(UserLibrary.isVodFavoriteKey('v:3'), isTrue);
      expect(UserLibrary.isSeriesFavoriteKey('s:8'), isTrue);
      expect(UserLibrary.isLiveFavoriteKey('i:1'), isTrue);
      expect(UserLibrary.isLiveFavoriteKey('v:1'), isFalse);
    });
  });
}
