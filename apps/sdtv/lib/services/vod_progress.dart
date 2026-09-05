/// Seconds stored before a title is treated as in-progress (resume).
const kVodResumeMinSeconds = 15;

/// True when [positionSecs] is far enough through [durationSecs] to count
/// as finished (continue-watching should clear; poster can show watched).
///
/// Unknown duration never counts as finished — we cannot tell credits from
/// a short play.
bool vodReachedEnd(int positionSecs, int durationSecs) {
  if (positionSecs <= kVodResumeMinSeconds || durationSecs <= 0) {
    return false;
  }
  if (positionSecs >= durationSecs - 60) return true;
  return positionSecs >= (durationSecs * 0.90).floor();
}
