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
      final once = const UserLibrary().withWatched('se:1');
      expect(once.withWatched('se:1').watchedKeys, ['se:1']);
    });

    test('key kind helpers', () {
      expect(UserLibrary.isVodFavoriteKey('v:3'), isTrue);
      expect(UserLibrary.isSeriesFavoriteKey('s:8'), isTrue);
      expect(UserLibrary.isLiveFavoriteKey('i:1'), isTrue);
      expect(UserLibrary.isLiveFavoriteKey('v:1'), isFalse);
    });
  });
}
