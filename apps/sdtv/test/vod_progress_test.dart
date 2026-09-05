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
}
