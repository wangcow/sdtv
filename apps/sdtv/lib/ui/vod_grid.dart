/// Layout + D-pad math for the Movies / TV Shows poster grid (no network I/O).
library;

const kVodGridPadding = 16.0;
const kVodGridSpacing = 10.0;
const kVodGridMinTileWidth = 148.0;
const kVodGridMinCols = 3;
const kVodGridMaxCols = 5;

/// Poster box (width / height). Title sits under this, not inside it.
const kVodPosterAspect = 2 / 3;

/// Tile width / height, including the title band under the 2:3 poster.
const kVodGridChildAspect = 0.54;

int vodGridCrossAxisCount(double width) {
  final inner = width - kVodGridPadding * 2;
  if (inner < kVodGridMinTileWidth) return 1;
  final cols =
      ((inner + kVodGridSpacing) / (kVodGridMinTileWidth + kVodGridSpacing))
          .floor();
  return cols.clamp(kVodGridMinCols, kVodGridMaxCols);
}

/// Vertical distance from one row top to the next (tile height + gap).
double vodGridRowStride({required double gridWidth, required int cols}) {
  final c = cols.clamp(1, kVodGridMaxCols);
  final inner = gridWidth - kVodGridPadding * 2;
  final tileW = (inner - kVodGridSpacing * (c - 1)) / c;
  final tileH = tileW / kVodGridChildAspect;
  return tileH + kVodGridSpacing;
}

/// Result of a grid D-pad step.
class VodGridMove {
  const VodGridMove._(this.index, this.leaveToCategories);

  final int index;
  final bool leaveToCategories;

  static VodGridMove stay(int index) => VodGridMove._(index, false);
  static const leave = VodGridMove._(0, true);
}

/// Couch grid: left on the first column returns to categories; up/down
/// move by a full row; right does not wrap to the next row.
VodGridMove moveVodGrid({
  required int index,
  required int count,
  required int cols,
  int dx = 0,
  int dy = 0,
}) {
  if (count <= 0) return VodGridMove.stay(0);
  final c = cols < 1 ? 1 : cols;
  var i = index.clamp(0, count - 1);
  final col = i % c;

  if (dx < 0) {
    if (col == 0) return VodGridMove.leave;
    return VodGridMove.stay(i - 1);
  }
  if (dx > 0) {
    if (i >= count - 1) return VodGridMove.stay(i);
    if (col == c - 1) return VodGridMove.stay(i);
    return VodGridMove.stay(i + 1);
  }
  if (dy != 0) {
    final next = i + dy * c;
    if (next < 0) return VodGridMove.stay(i);
    if (next >= count) {
      final row = i ~/ c;
      final lastRow = (count - 1) ~/ c;
      if (row >= lastRow) return VodGridMove.stay(i);
      return VodGridMove.stay(count - 1);
    }
    return VodGridMove.stay(next);
  }
  return VodGridMove.stay(i);
}
