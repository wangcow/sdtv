/// A short message on the video (volume, mute, retrying, notices), drawn by
/// the Flutter HUD instead of mpv's text OSD.
class HudToast {
  const HudToast({required this.text, this.icon, this.level});

  final String text;

  /// `volume`, `mute`, `retry`, or null for a plain notice.
  final String? icon;

  /// 0..1, shown as a bar (volume).
  final double? level;
}
