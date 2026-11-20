/// What the on-video pause / stall menu shows. The mpv HUD draws it as a
/// Flutter card; the ASS text menu is only the fallback.
class WatchMenuModel {
  const WatchMenuModel({
    required this.title,
    required this.rows,
    required this.selected,
    required this.hint,
    this.live = false,
    this.errorCode,
    this.errorMessage,
    this.timeLine,
    this.progress,
  });

  /// Now-playing label (channel, movie, or episode).
  final String title;
  final List<WatchMenuRow> rows;
  final int selected;
  final String hint;
  final bool live;

  /// Set on the stall / error menu, e.g. `A-HOLD` + `Playback stopped`.
  final String? errorCode;
  final String? errorMessage;

  /// VOD position, e.g. `12:04 / 1:32:10`, and 0..1 progress.
  final String? timeLine;
  final double? progress;

  bool get isError => errorCode != null;
}

class WatchMenuRow {
  const WatchMenuRow(
    this.id,
    this.label, {
    this.value,
    this.adjustable = false,
  });

  /// Menu action id (`resume`, `subtitles`, `retry`, `guide`, …).
  final String id;
  final String label;

  /// Current setting, e.g. subtitle track name or `On` / `Off`.
  final String? value;

  /// ←/→ changes [value] in place.
  final bool adjustable;

  /// `Label: value` for the text fallback.
  String get plain => value == null ? label : '$label: $value';
}
