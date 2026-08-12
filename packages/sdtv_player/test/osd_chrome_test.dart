import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_player/src/osd_chrome.dart';

void main() {
  test('assEscape strips braces that would break tags', () {
    expect(assEscape(r'CNN {HD}'), 'CNN (HD)');
    expect(assEscape(r'a\b'), r'a\\b');
  });

  test('liveBannerAss includes title and now/next', () {
    final ass = liveBannerAss(
      title: '5. ESPN',
      nowLine: 'NOW  7:00–8:00  Football',
      nextLine: 'NEXT 8:00  SportsCenter',
    );
    expect(ass, contains('5. ESPN'));
    expect(ass, contains('NOW'));
    expect(ass, contains('NEXT'));
    expect(ass, contains(r'\an2'));
  });

  test('watchMenuAss marks the selected row', () {
    final ass = watchMenuAss(
      title: 'ESPN',
      rows: const ['Resume', 'Audio: eng'],
      selected: 1,
    );
    expect(ass, contains('ESPN'));
    expect(ass, contains('Resume'));
    expect(ass, contains('▶  Audio: eng'));
  });
}
