/// Seconds stored before a title is treated as in-progress (resume).
const kVodResumeMinSeconds = 15;

/// Pick a credible duration from mpv vs provider metadata.
///
/// Xtream often puts **minutes** in `episode_run_time` / `duration_secs`
/// (e.g. Midsommar → 148). Treating that as seconds makes 10 minutes of
/// playback look "finished" and wipes resume.
int vodEffectiveDuration({
  required int positionSecs,
  required int mpvDurationSecs,
  required int catalogDurationSecs,
}) {
  if (mpvDurationSecs > 30) return mpvDurationSecs;
  if (catalogDurationSecs <= 0) return 0;
  if (positionSecs > catalogDurationSecs + 30 && catalogDurationSecs <= 500) {
    return catalogDurationSecs * 60;
  }
  return catalogDurationSecs;
}

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
