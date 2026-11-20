import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_player/sdtv_player.dart';

void main() {
  test('sdtv-key client messages become key presses', () async {
    final mpv = ExternalMpvLauncher();
    final got = <String>[];
    final sub = mpv.keyPresses.listen(got.add);
    mpv
      ..handleMpvEvent({
        'event': 'client-message',
        'args': ['sdtv-key', 'left'],
      })
      ..handleMpvEvent({
        'event': 'client-message',
        'args': ['other-script', 'x'],
      })
      ..handleMpvEvent({
        'event': 'client-message',
        'args': ['sdtv-key', 'back'],
      });
    await Future<void>.delayed(Duration.zero);
    expect(got, ['left', 'back']);
    await sub.cancel();
  });

  test('mpv acts on no key itself; navigation keys go to sdtv', () {
    final lines = mpvInputConf
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();
    String bindingFor(String key) =>
        lines.firstWhere((l) => l.split(' ').first == key);

    expect(bindingFor('ESC'), 'ESC script-message sdtv-key back');
    expect(bindingFor('LEFT'), 'LEFT script-message sdtv-key left');
    expect(bindingFor('SPACE'), 'SPACE script-message sdtv-key playpause');
    expect(bindingFor('q'), 'q script-message sdtv-key quit');
    // Quitting or pausing inside mpv would bypass progress saving and the HUD.
    for (final l in lines) {
      final cmd = l.substring(l.indexOf(' ') + 1);
      expect(cmd, isNot(startsWith('quit')), reason: l);
      expect(cmd, isNot(contains('cycle pause')), reason: l);
      expect(cmd, isNot(contains('playlist-')), reason: l);
    }
  });
}
