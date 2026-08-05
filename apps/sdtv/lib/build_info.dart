/// Build identity for verifying deploys on the Deck.
///
/// Set at package time:
///   flutter build linux --release --dart-define=SDTV_BUILD=abc1234-20260805-1200
class SdtvBuildInfo {
  SdtvBuildInfo._();

  /// From apps/sdtv/pubspec.yaml `version:` (major.minor.patch only here).
  static const version = '0.1.0';

  /// Injected by [tool/package-deck.sh]; `local` when run via flutter run.
  static const build = String.fromEnvironment(
    'SDTV_BUILD',
    defaultValue: 'local',
  );

  /// Short label for the guide chrome, e.g. `0.1.0 · a1b2c3d-20260805-1430`.
  static String get label => '$version · $build';

  /// Footer / About line.
  static String get detail => 'sdtv $label';
}
