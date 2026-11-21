import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_player/sdtv_player.dart';

/// mpv stand-in: no play position until the [startsOnLoad]-th loadfile.
class _ColdPanelMpv extends ExternalMpvLauncher {
  _ColdPanelMpv({required this.startsOnLoad});

  final int startsOnLoad;
  final loads = <String>[];
  bool sawStartCheck = false;

  @override
  bool get isRunning => true;

  @override
  Future<bool> sendCommand(List<Object?> command) async {
    if (command.first == 'loadfile') loads.add('${command[1]}');
    return true;
  }

  @override
  Future<Object?> getProperty(String name) async {
    sawStartCheck |= startCheckInFlight;
    if (name == 'time-pos' && loads.length >= startsOnLoad) return 1.0;
    return null;
  }
}

void main() {
  final primary = Uri.parse('http://panel.example/live/u/p/1.ts');
  final fallback = Uri.parse('http://panel.example/live/u/p/1.m3u8');
  const quick = Duration(milliseconds: 300);

  test(
    'a silent first start reloads the same URL before the fallback',
    () async {
      final mpv = _ColdPanelMpv(startsOnLoad: 2);
      await mpv.loadFile(primary);

      final ok = await mpv.waitUntilHealthyOrFallback(fallback, timeout: quick);

      expect(ok, isTrue);
      expect(mpv.loads, ['$primary', '$primary']); // no .m3u8
      expect(mpv.sawStartCheck, isTrue);
      expect(mpv.startCheckInFlight, isFalse);
    },
  );

  test('the fallback still follows when the reload stays silent', () async {
    final mpv = _ColdPanelMpv(startsOnLoad: 3);
    await mpv.loadFile(primary);

    final ok = await mpv.waitUntilHealthyOrFallback(fallback, timeout: quick);

    expect(ok, isTrue);
    expect(mpv.loads, ['$primary', '$primary', '$fallback']);
    expect(mpv.startCheckInFlight, isFalse);
  });
}
