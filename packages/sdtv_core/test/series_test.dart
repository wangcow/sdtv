import 'package:sdtv_core/sdtv_core.dart';
import 'package:test/test.dart';

void main() {
  test('SeriesItem.fromJson reads stringy ids and asVodItem', () {
    final item = SeriesItem.fromJson({
      'series_id': '8001',
      'name': 'Harbor Nights',
      'category_id': 20,
      'cover': 'http://example.com/h.jpg',
      'plot': 'A harbor.',
      'rating': '8.1',
    });
    expect(item.seriesId, 8001);
    expect(item.categoryId, '20');
    expect(item.favoriteKey, 's:8001');
    expect(item.asVodItem.streamId, 8001);
    expect(item.asVodItem.name, 'Harbor Nights');
    expect(item.asVodItem.streamIcon, 'http://example.com/h.jpg');
  });

  test('SeriesCatalog.fromXtreamJson groups seasons and episodes', () {
    final cat = SeriesCatalog.fromXtreamJson({
      'info': {
        'name': 'Harbor Nights',
        'plot': 'A mock prestige drama.',
        'director': 'Riley Showrunner',
        'actors': 'Avery Dock, Quinn Harbor',
        'genre': 'Drama',
        'releasedate': '2024',
        'rating': '8.1',
        'youtube_trailer': 'dQw4w9wgXcQ',
        'cover': 'http://example.com/h.jpg',
      },
      'episodes': {
        '2': [
          {
            'id': '8201',
            'episode_num': 1,
            'title': 'Low Tide',
            'container_extension': 'mkv',
            'info': {'plot': 'Season two.', 'duration_secs': 2520},
          },
        ],
        '1': [
          {
            'id': '8102',
            'episode_num': 2,
            'title': 'Fog Line',
            'container_extension': 'mp4',
          },
          {
            'id': '8101',
            'episode_num': 1,
            'title': 'Pilot',
            'container_extension': 'mp4',
          },
        ],
      },
    });

    expect(cat.info.title, 'Harbor Nights');
    expect(cat.info.hasTrailer, isTrue);
    expect(cat.info.isYoutubeTrailer, isTrue);
    expect(cat.seasons, hasLength(2));
    expect(cat.seasons.first.seasonNumber, 1);
    expect(cat.seasons.first.name, 'Season 1');
    expect(cat.seasons.first.episodes.map((e) => e.episodeNum), [1, 2]);
    expect(cat.firstEpisode?.id, '8101');
    expect(cat.firstEpisode?.label, 'E1  Pilot');
    expect(cat.episodeById('8201')?.containerExtension, 'mkv');
    expect(cat.episodeById('8201')?.progressKey, 'se:8201');
    expect(cat.seasons.last.name, 'Season 2');
    expect(cat.nextEpisode(cat.episodeById('8101')!)?.id, '8102');
    expect(cat.nextEpisode(cat.episodeById('8102')!)?.id, '8201');
    expect(cat.nextEpisode(cat.episodeById('8201')!), isNull);
    expect(
      cat.nextEpisode(
        const SeriesEpisode(
          id: 'missing',
          season: 1,
          episodeNum: 9,
          title: 'Gone',
        ),
      ),
      isNull,
    );
  });

  test('seriesStreamUri uses /series/user/pass/id.ext', () {
    final creds = XtreamCredentials(
      baseUrl: 'http://example.com:8080',
      username: 'u',
      password: 'secret',
    );
    expect(
      creds.seriesStreamUri('8101', extension: 'mkv').toString(),
      'http://example.com:8080/series/u/secret/8101.mkv',
    );
  });
}
