import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_player/src/osd_chrome.dart';

void main() {
  test('assEscape strips braces that would break tags', () {
    expect(assEscape(r'CNN {HD}'), 'CNN (HD)');
    expect(assEscape(r'a\b'), r'a\\b');
  });

  test('liveBannerAss includes LIVE badge, title and now/next', () {
    final ass = liveBannerAss(
      title: '5. ESPN',
      nowLine: 'NOW  7:00–8:00  Football',
      nextLine: 'NEXT 8:00  SportsCenter',
    );
    expect(ass, contains('● LIVE'));
    expect(ass, contains('5. ESPN'));
    expect(ass, contains('NOW'));
    expect(ass, contains('NEXT'));
    expect(ass, contains(r'\an2'));
  });

  test('liveBannerPlain is readable without ASS tags', () {
    final plain = liveBannerPlain(
      title: '5. ESPN',
      nowLine: 'NOW  Football',
    );
    expect(plain, contains('● LIVE'));
    expect(plain, contains('5. ESPN'));
    expect(plain, isNot(contains(r'{\')));
  });

  test('watchMenuAss marks the selected row', () {
    final ass = watchMenuAss(
      title: 'ESPN',
      rows: const ['Resume', 'Audio: eng'],
      selected: 1,
      live: true,
    );
    expect(ass, contains('ESPN'));
    expect(ass, contains('● LIVE'));
    expect(ass, contains('Resume'));
    expect(ass, contains('▶  Audio: eng'));
  });

  test('vodHudAss includes a progress bar', () {
    final ass = vodHudAss(
      title: 'Harbor Nights',
      timeLine: '12:04 / 22:00',
      progress: 0.5,
    );
    expect(ass, contains('Harbor Nights'));
    expect(ass, contains('12:04'));
    expect(ass, contains('█'));
    expect(ass, contains('░'));
  });

  test('osdProgressBar fills by ratio', () {
    expect(osdProgressBar(0, width: 10), '░' * 10);
    expect(osdProgressBar(1, width: 10), '█' * 10);
    expect(osdProgressBar(0.5, width: 10), '${'█' * 5}${'░' * 5}');
  });
}
