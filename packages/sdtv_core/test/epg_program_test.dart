import 'dart:convert';

import 'package:sdtv_core/sdtv_core.dart';
import 'package:test/test.dart';

void main() {
  group('EpgProgram.fromXtreamJson', () {
    test('decodes base64 title and unix timestamps', () {
      final title = base64.encode(utf8.encode('Evening News'));
      final p = EpgProgram.fromXtreamJson({
        'id': '1',
        'title': title,
        'description': base64.encode(utf8.encode('Local headlines')),
        'start_timestamp': '1700000000',
        'stop_timestamp': '1700003600',
      });
      expect(p.title, 'Evening News');
      expect(p.description, 'Local headlines');
      expect(p.end.difference(p.start), const Duration(hours: 1));
    });

    test('keeps plain-text titles that are not base64', () {
      final p = EpgProgram.fromXtreamJson({
        'title': 'Live Soccer',
        'start': '2024-06-01 20:00:00',
        'end': '2024-06-01 22:00:00',
      });
      expect(p.title, 'Live Soccer');
      expect(p.duration, const Duration(hours: 2));
    });
  });

  group('ShortEpg now/next', () {
    final t0 = DateTime(2026, 8, 5, 20, 15); // 8:15 PM
    final listings = [
      EpgProgram(
        title: 'Past Show',
        start: DateTime(2026, 8, 5, 18, 0),
        end: DateTime(2026, 8, 5, 19, 0),
      ),
      EpgProgram(
        title: 'Current Show',
        start: DateTime(2026, 8, 5, 20, 0),
        end: DateTime(2026, 8, 5, 21, 0),
      ),
      EpgProgram(
        title: 'Next Show',
        start: DateTime(2026, 8, 5, 21, 0),
        end: DateTime(2026, 8, 5, 22, 0),
      ),
    ];
    final epg = ShortEpg(streamId: 1, listings: listings);

    test('nowAt finds live program', () {
      expect(epg.nowAt(t0)?.title, 'Current Show');
    });

    test('nextAt is the following slot', () {
      expect(epg.nextAt(t0)?.title, 'Next Show');
    });

    test('progress is mid-slot', () {
      final now = epg.nowAt(t0)!;
      expect(now.progressAt(t0), closeTo(0.25, 0.01));
    });

    test('formatOsd includes NOW and NEXT', () {
      final text = epg.formatOsd(channelLabel: '42. CNN', prefix: '→', at: t0);
      expect(text, contains('→ 42. CNN'));
      expect(text, contains('NOW'));
      expect(text, contains('Current Show'));
      expect(text, contains('NEXT'));
      expect(text, contains('Next Show'));
    });

    test('guideSubtitle is one line', () {
      final s = epg.guideSubtitle(at: t0);
      expect(s, isNotNull);
      expect(s, contains('Current Show'));
    });
  });

  group('MockXtreamClient short EPG', () {
    test('returns synthetic listings', () async {
      final client = MockXtreamClient(
        authJson: '{}',
        liveCategoriesJson: '[]',
        liveStreamsJson: '[]',
      );
      // authenticate not required for mock EPG
      final epg = await client.getShortEpg(101, limit: 3);
      expect(epg.listings, hasLength(3));
      expect(epg.nowAt(), isNotNull);
      expect(epg.nextAt(), isNotNull);
    });

    test('getSimpleEpg returns a full-day table', () async {
      final client = MockXtreamClient(
        authJson: '{}',
        liveCategoriesJson: '[]',
        liveStreamsJson: '[]',
      );
      final epg = await client.getSimpleEpg(101);
      expect(epg.listings.length, greaterThan(20));
      expect(epg.nowAt(), isNotNull);
      final win = epg.inWindow(
        DateTime.now().subtract(const Duration(hours: 1)),
        DateTime.now().add(const Duration(hours: 2)),
      );
      expect(win, isNotEmpty);
    });
  });
}
