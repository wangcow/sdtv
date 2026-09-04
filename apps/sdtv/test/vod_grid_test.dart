import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv/ui/vod_grid.dart';

void main() {
  group('vodGridCrossAxisCount', () {
    test('clamps to 3–5 on typical Deck / TV widths', () {
      expect(vodGridCrossAxisCount(400), 3);
      expect(vodGridCrossAxisCount(720), inInclusiveRange(3, 5));
      expect(vodGridCrossAxisCount(1600), 5);
    });
  });

  group('moveVodGrid', () {
    test('left on first column leaves to categories', () {
      final m = moveVodGrid(index: 4, count: 10, cols: 4, dx: -1);
      expect(m.leaveToCategories, isTrue);
    });

    test('left inside a row steps one tile', () {
      final m = moveVodGrid(index: 2, count: 10, cols: 4, dx: -1);
      expect(m.leaveToCategories, isFalse);
      expect(m.index, 1);
    });

    test('right does not wrap to the next row', () {
      final m = moveVodGrid(index: 3, count: 10, cols: 4, dx: 1);
      expect(m.index, 3);
      expect(m.leaveToCategories, isFalse);
    });

    test('right on last item stays', () {
      final m = moveVodGrid(index: 9, count: 10, cols: 4, dx: 1);
      expect(m.index, 9);
    });

    test('down moves a full row', () {
      final m = moveVodGrid(index: 1, count: 10, cols: 4, dy: 1);
      expect(m.index, 5);
    });

    test('down from last full row lands on last item', () {
      final m = moveVodGrid(index: 1, count: 6, cols: 4, dy: 1);
      expect(m.index, 5);
    });

    test('down on last row stays', () {
      final m = moveVodGrid(index: 5, count: 6, cols: 4, dy: 1);
      expect(m.index, 5);
    });

    test('up from first row stays', () {
      final m = moveVodGrid(index: 2, count: 10, cols: 4, dy: -1);
      expect(m.index, 2);
    });

    test('empty catalog is index 0', () {
      final m = moveVodGrid(index: 3, count: 0, cols: 4, dy: 1);
      expect(m.index, 0);
    });
  });
}
