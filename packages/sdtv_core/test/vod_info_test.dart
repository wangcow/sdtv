import 'package:sdtv_core/sdtv_core.dart';
import 'package:test/test.dart';

void main() {
  test('VodInfo.fromXtreamJson reads info + movie_data', () {
    final info = VodInfo.fromXtreamJson({
      'info': {
        'name': 'Heat',
        'plot': 'Cops and robbers.',
        'director': 'Michael Mann',
        'actors': 'Al Pacino, Robert De Niro, Val Kilmer',
        'genre': 'Crime',
        'releasedate': '1995',
        'rating': '8.3',
        'youtube_trailer': 'dQw4w9wgXcQ',
        'movie_image': 'http://example.com/p.jpg',
        'duration_secs': 10200,
      },
      'movie_data': {'stream_id': 1, 'name': 'Heat'},
    });
    expect(info.title, 'Heat');
    expect(info.director, 'Michael Mann');
    expect(info.billedCast, ['Al Pacino', 'Robert De Niro', 'Val Kilmer']);
    expect(info.hasTrailer, isTrue);
    expect(info.isYoutubeTrailer, isTrue);
    expect(
      info.trailerUri.toString(),
      'https://www.youtube.com/watch?v=dQw4w9wgXcQ',
    );
    expect(info.posterUrl, 'http://example.com/p.jpg');
    expect(info.ratingSource, 'Provider');
  });

  test('VodInfo.fromVodItem is a safe fallback', () {
    const item = VodItem(
      streamId: 9,
      name: 'Fallback',
      categoryId: '1',
      plot: 'p',
      rating: '5',
    );
    final info = VodInfo.fromVodItem(item);
    expect(info.title, 'Fallback');
    expect(info.hasTrailer, isFalse);
    expect(info.plot, 'p');
  });

  test('youtubeVideoId parses id, youtu.be, and watch URLs', () {
    expect(VodInfo.youtubeVideoId('dQw4w9wgXcQ'), 'dQw4w9wgXcQ');
    expect(
      VodInfo.youtubeVideoId('https://youtu.be/dQw4w9wgXcQ'),
      'dQw4w9wgXcQ',
    );
    expect(
      VodInfo.youtubeVideoId(
        'https://www.youtube.com/watch?v=dQw4w9wgXcQ&t=12',
      ),
      'dQw4w9wgXcQ',
    );
    expect(
      VodInfo.youtubeVideoId('https://www.youtube.com/embed/dQw4w9wgXcQ'),
      'dQw4w9wgXcQ',
    );
    expect(
      VodInfo.youtubeVideoId(
        'https://devstreaming-cdn.apple.com/x/master.m3u8',
      ),
      isNull,
    );
  });
}
