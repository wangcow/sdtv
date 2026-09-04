import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv/ui/epg_grid.dart';
import 'package:sdtv_core/sdtv_core.dart';

void main() {
  group('epgSnapDown', () {
    test('snaps to :00 or :30', () {
      expect(
        epgSnapDown(DateTime(2026, 9, 4, 20, 14)),
        DateTime(2026, 9, 4, 20, 0),
      );
      expect(
        epgSnapDown(DateTime(2026, 9, 4, 20, 30)),
        DateTime(2026, 9, 4, 20, 30),
      );
      expect(
        epgSnapDown(DateTime(2026, 9, 4, 20, 59)),
        DateTime(2026, 9, 4, 20, 30),
      );
    });
  });

  group('epgLayoutFor', () {
    test('slot pixels fill the program width', () {
      final start = DateTime(2026, 9, 4, 20, 0);
      final layout = epgLayoutFor(windowStart: start, programWidth: 720);
      expect(layout.windowStart, start);
      expect(layout.length.inMinutes, inInclusiveRange(120, 360));
      expect(layout.xFor(layout.windowEnd), 720);
      expect(layout.contains(start.add(const Duration(minutes: 1))), isTrue);
      expect(layout.contains(layout.windowEnd), isFalse);
    });

    test('program starting on a tick shares that tick x', () {
      final start = DateTime(2026, 9, 4, 20, 0);
      final layout = epgLayoutFor(windowStart: start, programWidth: 600);
      final tick = start.add(const Duration(minutes: 30));
      expect(layout.clipLeft(tick), layout.xFor(tick));
      expect(
        layout.clipWidth(tick, tick.add(const Duration(minutes: 30))),
        layout.xFor(tick.add(const Duration(minutes: 30))) - layout.xFor(tick),
      );
    });

    test('clips a program that starts before the window', () {
      final start = DateTime(2026, 9, 4, 20, 0);
      final layout = epgLayoutFor(windowStart: start, programWidth: 600);
      final left = layout.clipLeft(start.subtract(const Duration(minutes: 30)));
      expect(left, 0);
      final w = layout.clipWidth(
        start.subtract(const Duration(minutes: 15)),
        start.add(const Duration(minutes: 15)),
      );
      expect(w, greaterThan(0));
      expect(w, lessThan(layout.programWidth));
    });
  });

  group('epgEnsureVisible', () {
    test('stays when the program already fits', () {
      final win = DateTime(2026, 9, 4, 20, 0);
      final next = epgEnsureVisible(
        windowStart: win,
        windowLength: const Duration(hours: 3),
        start: DateTime(2026, 9, 4, 20, 30),
        end: DateTime(2026, 9, 4, 21, 0),
      );
      expect(next, win);
    });

    test('shifts left to show an earlier program', () {
      final win = DateTime(2026, 9, 4, 20, 0);
      final next = epgEnsureVisible(
        windowStart: win,
        windowLength: const Duration(hours: 3),
        start: DateTime(2026, 9, 4, 18, 0),
        end: DateTime(2026, 9, 4, 19, 0),
      );
      expect(next, DateTime(2026, 9, 4, 18, 0));
    });

    test('nudges forward by slots and reverses on the way back', () {
      const len = Duration(hours: 3);
      final win = DateTime(2026, 9, 4, 20, 0);
      final forward = epgEnsureVisible(
        windowStart: win,
        windowLength: len,
        start: DateTime(2026, 9, 4, 23, 30),
        end: DateTime(2026, 9, 5, 0, 0),
      );
      expect(forward.isAfter(win), isTrue);
      expect(forward.minute, anyOf(0, 30));
      final back = epgEnsureVisible(
        windowStart: forward,
        windowLength: len,
        start: DateTime(2026, 9, 4, 20, 0),
        end: DateTime(2026, 9, 4, 20, 30),
      );
      expect(back, win);
    });
  });

  group('epgNeedsReturnToNow', () {
    final now = DateTime(2026, 9, 4, 20, 14);

    test('false when window and live listing are now', () {
      expect(
        epgNeedsReturnToNow(
          windowStart: DateTime(2026, 9, 4, 20, 0),
          focusTime: now,
          now: now,
          focusedIndex: 1,
          liveIndex: 1,
        ),
        isFalse,
      );
    });

    test('true when the window has been paged forward', () {
      expect(
        epgNeedsReturnToNow(
          windowStart: DateTime(2026, 9, 4, 22, 0),
          focusTime: DateTime(2026, 9, 4, 22, 5),
          now: now,
          focusedIndex: 3,
          liveIndex: 1,
        ),
        isTrue,
      );
    });

    test('true when focus is a later program in the now window', () {
      expect(
        epgNeedsReturnToNow(
          windowStart: DateTime(2026, 9, 4, 20, 0),
          focusTime: DateTime(2026, 9, 4, 21, 1),
          now: now,
          focusedIndex: 2,
          liveIndex: 1,
        ),
        isTrue,
      );
    });

    test('true from a future focusTime when listings are unknown', () {
      expect(
        epgNeedsReturnToNow(
          windowStart: DateTime(2026, 9, 4, 20, 0),
          focusTime: DateTime(2026, 9, 4, 21, 0),
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('ShortEpg window helpers', () {
    final listings = [
      EpgProgram(
        title: 'A',
        start: DateTime(2026, 9, 4, 19, 0),
        end: DateTime(2026, 9, 4, 20, 0),
      ),
      EpgProgram(
        title: 'B',
        start: DateTime(2026, 9, 4, 20, 0),
        end: DateTime(2026, 9, 4, 21, 30),
      ),
      EpgProgram(
        title: 'C',
        start: DateTime(2026, 9, 4, 21, 30),
        end: DateTime(2026, 9, 4, 22, 0),
      ),
    ];
    final epg = ShortEpg(streamId: 1, listings: listings);

    test('inWindow includes overlaps only', () {
      final hit = epg.inWindow(
        DateTime(2026, 9, 4, 20, 0),
        DateTime(2026, 9, 4, 21, 0),
      );
      expect(hit.map((p) => p.title), ['B']);
    });

    test('indexForTime prefers the live listing', () {
      expect(epg.indexForTime(DateTime(2026, 9, 4, 20, 15)), 1);
      expect(epg.indexForTime(DateTime(2026, 9, 4, 18, 0)), 0);
      expect(epg.indexForTime(DateTime(2026, 9, 4, 23, 0)), 2);
    });
  });
}
