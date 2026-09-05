import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv/services/vod_progress.dart';

void main() {
  group('vodReachedEnd', () {
    test('unknown duration is never finished', () {
      expect(vodReachedEnd(0, 0), isFalse);
      expect(vodReachedEnd(90, 0), isFalse);
    });

    test('short plays do not count', () {
      expect(vodReachedEnd(10, 3600), isFalse);
      expect(vodReachedEnd(15, 3600), isFalse);
    });

    test('last minute counts', () {
      expect(vodReachedEnd(3540, 3600), isTrue);
      expect(vodReachedEnd(3600, 3600), isTrue);
    });

    test('90 percent counts', () {
      expect(vodReachedEnd(3240, 3600), isTrue);
      expect(vodReachedEnd(90, 100), isTrue);
    });

    test('mid-title does not count', () {
      expect(vodReachedEnd(1800, 3600), isFalse);
      expect(vodReachedEnd(3000, 3600), isFalse);
    });
  });

  group('vodEffectiveDuration', () {
    test('prefers mpv duration', () {
      expect(
        vodEffectiveDuration(
          positionSecs: 600,
          mpvDurationSecs: 8880,
          catalogDurationSecs: 148,
        ),
        8880,
      );
    });

    test('treats short catalog values as minutes when playback is past them', () {
      expect(
        vodEffectiveDuration(
          positionSecs: 600,
          mpvDurationSecs: 0,
          catalogDurationSecs: 148,
        ),
        148 * 60,
      );
    });

    test('keeps catalog seconds when they already look like a runtime', () {
      expect(
        vodEffectiveDuration(
          positionSecs: 600,
          mpvDurationSecs: 0,
          catalogDurationSecs: 8880,
        ),
        8880,
      );
    });
  });
}
