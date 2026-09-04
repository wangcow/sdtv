/// Layout + D-pad math for the TV Guide grid (no network I/O).
library;

const kEpgSlot = Duration(minutes: 30);
const kEpgJump = Duration(hours: 2);
const kEpgRowExtent = 68.0;

/// Shared channel-name column. Header ticks and program cells must both
/// start exactly this many pixels from the pane left.
const kEpgGutterWidth = 176.0;
const kEpgHeaderHeight = 40.0;
const kEpgTimeHeaderHeight = 36.0;

/// Snap [t] down to a 30-minute wall-clock boundary (local).
DateTime epgSnapDown(DateTime t) {
  final m = t.minute < 30 ? 0 : 30;
  return DateTime(t.year, t.month, t.day, t.hour, m);
}

/// Visible window length: whole 30-minute slots, ~3 px/minute.
Duration epgWindowLength(double programWidth) {
  if (programWidth <= 0) return const Duration(hours: 3);
  const targetPpm = 3.0;
  final slots =
      (programWidth / (kEpgSlot.inMinutes * targetPpm)).floor().clamp(4, 16);
  return Duration(minutes: slots * kEpgSlot.inMinutes);
}

/// Pixels per minute so [epgWindowLength] fills [programWidth] exactly.
double epgPxPerMinute(double programWidth) {
  final minutes = epgWindowLength(programWidth).inMinutes;
  if (minutes <= 0 || programWidth <= 0) return 3.0;
  return programWidth / minutes;
}

class EpgLayout {
  const EpgLayout({
    required this.windowStart,
    required this.windowEnd,
    required this.pxPerMinute,
    required this.programWidth,
  });

  final DateTime windowStart;
  final DateTime windowEnd;
  final double pxPerMinute;
  final double programWidth;

  Duration get length => windowEnd.difference(windowStart);

  bool contains(DateTime t) =>
      !t.isBefore(windowStart) && t.isBefore(windowEnd);

  /// X in the program column. Slot boundaries and program edges share this.
  double xFor(DateTime t) {
    if (!t.isAfter(windowStart)) return 0;
    if (!t.isBefore(windowEnd)) return programWidth;
    final min = t.difference(windowStart).inMilliseconds / 60000.0;
    return (min * pxPerMinute).roundToDouble().clamp(0.0, programWidth);
  }

  /// Left edge of [start], clipped to the window.
  double clipLeft(DateTime start) {
    final t = start.isBefore(windowStart) ? windowStart : start;
    return xFor(t);
  }

  /// Width of `[start, end)` clipped to the window. 0 if no overlap.
  ///
  /// Uses [xFor] on both ends so a program that starts on a tick shares that
  /// tick's pixel with the axis (going right then left stays aligned).
  double clipWidth(DateTime start, DateTime end) {
    final a = start.isBefore(windowStart) ? windowStart : start;
    final b = end.isAfter(windowEnd) ? windowEnd : end;
    if (!a.isBefore(b)) return 0;
    return (xFor(b) - xFor(a)).clamp(0.0, programWidth);
  }

  List<DateTime> get ticks {
    final out = <DateTime>[];
    var t = windowStart;
    while (t.isBefore(windowEnd)) {
      out.add(t);
      t = t.add(kEpgSlot);
    }
    return out;
  }
}

EpgLayout epgLayoutFor({
  required DateTime windowStart,
  required double programWidth,
}) {
  final snapped = epgSnapDown(windowStart);
  final len = epgWindowLength(programWidth);
  final width = programWidth < 120 ? 120.0 : programWidth;
  return EpgLayout(
    windowStart: snapped,
    windowEnd: snapped.add(len),
    pxPerMinute: epgPxPerMinute(width),
    programWidth: width,
  );
}

/// Shift [windowStart] by [delta], snapped. Does not clamp to data.
DateTime epgShiftWindow(DateTime windowStart, Duration delta) {
  return epgSnapDown(windowStart.add(delta));
}

/// Nudge [windowStart] by whole 30-minute slots until [start] is in view.
///
/// Reversible: moving to a later program then back uses the same snap grid,
/// instead of anchoring to the program's end (which drifted the axis).
DateTime epgEnsureVisible({
  required DateTime windowStart,
  required Duration windowLength,
  required DateTime start,
  required DateTime end,
}) {
  var win = epgSnapDown(windowStart);
  if (windowLength <= Duration.zero) return win;

  bool startInWindow() {
    final we = win.add(windowLength);
    return !start.isBefore(win) && start.isBefore(we);
  }

  if (startInWindow()) return win;

  // Keep still when only the tail of an earlier program is on-screen.
  final we = win.add(windowLength);
  if (start.isBefore(win) && end.isAfter(win)) return win;

  if (!start.isBefore(we)) {
    while (!start.isBefore(win.add(windowLength))) {
      win = win.add(kEpgSlot);
    }
    return win;
  }
  while (start.isBefore(win)) {
    win = win.subtract(kEpgSlot);
  }
  return win;
}

/// True when B on the guide should snap to now instead of leaving to
/// categories: the window is away from now, or focus is not the live listing.
bool epgNeedsReturnToNow({
  required DateTime windowStart,
  required DateTime focusTime,
  required DateTime now,
  int? focusedIndex,
  int? liveIndex,
}) {
  if (epgSnapDown(windowStart) != epgSnapDown(now)) return true;
  if (focusedIndex != null && liveIndex != null) {
    return focusedIndex != liveIndex;
  }
  return focusTime.isAfter(now);
}

String epgAxisLabel(DateTime t, {bool use24h = false}) {
  final clock = _clock(t, use24h: use24h);
  if (t.hour == 0 && t.minute == 0) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${days[t.weekday - 1]} $clock';
  }
  return clock;
}

String _clock(DateTime t, {required bool use24h}) {
  if (use24h) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
  final hour12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  final ampm = t.hour >= 12 ? 'PM' : 'AM';
  return '$hour12:$m $ampm';
}
