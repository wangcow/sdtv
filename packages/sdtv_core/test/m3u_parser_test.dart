import 'package:sdtv_core/sdtv_core.dart';
import 'package:test/test.dart';

void main() {
  test('parses EXTINF groups and stream URLs', () {
    const raw = '''
#EXTM3U
#EXTINF:-1 tvg-id="n1" tvg-logo="http://img/n.png" group-title="News",News One
http://example.com/news1.m3u8
#EXTINF:-1 group-title="News",News Two
https://example.com/news2.ts
#EXTINF:-1 group-title="Sports",Sports HD
http://cdn.example/sport.m3u8
''';
    final pl = M3uParser.parse(raw);
    expect(pl.categories, hasLength(2));
    expect(pl.categories.map((c) => c.categoryName), containsAll(['News', 'Sports']));
    expect(pl.channels, hasLength(3));
    expect(pl.channels[0].name, 'News One');
    expect(pl.channels[0].hasDirectUrl, isTrue);
    expect(pl.channels[0].streamUrl, 'http://example.com/news1.m3u8');
    expect(pl.channels[0].streamIcon, 'http://img/n.png');
    expect(pl.channels[2].categoryId, isNot(pl.channels[0].categoryId));
  });

  test('resolves relative URLs against playlist base', () {
    final pl = M3uParser.parse(
      '#EXTM3U\n#EXTINF:-1,Rel\nstreams/a.m3u8\n',
      baseUri: Uri.parse('https://cdn.example/list/playlist.m3u'),
    );
    expect(pl.channels.single.streamUrl, 'https://cdn.example/list/streams/a.m3u8');
  });

  test('rejects empty garbage', () {
    expect(() => M3uParser.parse('hello world'), throwsA(isA<XtreamException>()));
  });
}
