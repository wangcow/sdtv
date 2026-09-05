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

    test('does not return live channel categories', () {
      final hits = GuideSearch.search(
        query: 'sports',
        categories: cats,
        channels: channels,
      );
      expect(hits.any((h) => h.isCategory), isFalse);
      expect(
        hits.any((h) => h.isChannel && h.channel?.name == 'ESPN HD'),
        isTrue,
      );
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

    test('marks favorited channels in subtitle and score', () {
      final hits = GuideSearch.search(
        query: 'bloomberg',
        categories: cats,
        channels: channels,
        favoriteKeys: {channels[0].favoriteKey},
      );
      expect(hits, isNotEmpty);
      final bloom = hits.firstWhere(
        (h) => h.channel?.name.contains('Bloomberg') ?? false,
      );
      expect(bloom.subtitle, contains('★'));
      expect(bloom.score, greaterThan(40));
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

    final vodCats = [
      (id: 'm1', name: 'Action'),
      (id: 'm2', name: 'Comedy'),
    ];
    final vods = [
      const VodItem(
        streamId: 101,
        name: 'The Batman',
        categoryId: 'm1',
      ),
      const VodItem(
        streamId: 102,
        name: 'Superbad',
        categoryId: 'm2',
      ),
    ];
    final seriesCats = [
      (id: 's1', name: 'Sitcoms'),
    ];
    final shows = [
      const SeriesItem(
        seriesId: 201,
        name: 'Friends',
        categoryId: 's1',
      ),
    ];

    test('finds a movie by title', () {
      final hits = GuideSearch.search(
        query: 'batman',
        categories: cats,
        channels: channels,
        vodCategories: vodCats,
        vodItems: vods,
      );
      expect(hits.any((h) => h.isVod && h.vod?.name == 'The Batman'), isTrue);
      final movie = hits.firstWhere((h) => h.isVod);
      expect(movie.section, GuideSearchSection.movies);
      expect(movie.subtitle, contains('Movie'));
    });

    test('finds a TV show by title', () {
      final hits = GuideSearch.search(
        query: 'friends',
        categories: cats,
        channels: channels,
        seriesCategories: seriesCats,
        seriesItems: shows,
      );
      expect(hits.any((h) => h.isSeries && h.series?.name == 'Friends'), isTrue);
      expect(
        hits.firstWhere((h) => h.isSeries).section,
        GuideSearchSection.series,
      );
    });

    test('finds a movie category', () {
      final hits = GuideSearch.search(
        query: 'action',
        categories: cats,
        channels: channels,
        vodCategories: vodCats,
        vodItems: vods,
      );
      expect(
        hits.any(
          (h) =>
              h.isCategory &&
              h.section == GuideSearchSection.movies &&
              h.categoryId == 'm1',
        ),
        isTrue,
      );
    });

    test('marks hidden movie categories', () {
      final hits = GuideSearch.search(
        query: 'batman',
        categories: cats,
        channels: channels,
        vodCategories: vodCats,
        vodItems: vods,
        hiddenCategoryIds: {'m1'},
      );
      final movie = hits.firstWhere((h) => h.isVod);
      expect(movie.subtitle, contains('hidden'));
    });

    test('live hits still win when catalogs are empty extras', () {
      final hits = GuideSearch.search(
        query: 'bloom',
        categories: cats,
        channels: channels,
        vodCategories: vodCats,
        vodItems: vods,
      );
      expect(hits.first.isChannel, isTrue);
      expect(hits.first.channel?.name, contains('Bloomberg'));
    });
  });
}
