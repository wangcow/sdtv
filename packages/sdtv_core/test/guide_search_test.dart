import 'package:sdtv_core/sdtv_core.dart';
import 'package:test/test.dart';

void main() {
  group('GuideSearch', () {
    final cats = [
      (id: '1', name: 'USA Entertainment'),
      (id: '2', name: 'USA Sports'),
      (id: '3', name: 'Algeria'),
    ];
    final channels = [
      const LiveChannel(
        streamId: 10,
        name: 'Bloomberg TV',
        categoryId: '1',
        num: 10,
      ),
      const LiveChannel(
        streamId: 11,
        name: 'ESPN HD',
        categoryId: '2',
        num: 11,
      ),
      const LiveChannel(
        streamId: 12,
        name: 'Local Algeria 1',
        categoryId: '3',
        num: 12,
      ),
    ];

    test('finds channel by partial name', () {
      final hits = GuideSearch.search(
        query: 'bloom',
        categories: cats,
        channels: channels,
      );
      expect(hits, isNotEmpty);
      expect(hits.first.isChannel, isTrue);
      expect(hits.first.channel?.name, contains('Bloomberg'));
    });

    test('finds category', () {
      final hits = GuideSearch.search(
        query: 'sports',
        categories: cats,
        channels: channels,
      );
      expect(hits.any((h) => h.isCategory && h.categoryId == '2'), isTrue);
    });

    test('still finds channels in hidden categories (marked)', () {
      final hits = GuideSearch.search(
        query: 'algeria',
        categories: cats,
        channels: channels,
        hiddenCategoryIds: {'3'},
      );
      expect(hits, isNotEmpty);
      expect(hits.any((h) => h.subtitle.contains('hidden')), isTrue);
    });

    test('boosts favorited channels', () {
      final hits = GuideSearch.search(
        query: 'e',
        categories: cats,
        channels: channels,
        favoriteKeys: {channels[0].favoriteKey},
      );
      expect(hits.first.channel?.name, contains('Bloomberg'));
    });

    test('empty query returns nothing', () {
      expect(
        GuideSearch.search(
          query: '  ',
          categories: cats,
          channels: channels,
        ),
        isEmpty,
      );
    });
  });
}
