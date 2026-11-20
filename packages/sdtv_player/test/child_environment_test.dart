import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_player/sdtv_player.dart';

void main() {
  const parent = {
    'HOME': '/home/deck',
    'LD_LIBRARY_PATH': '/usr/lib64:/usr/lib:/home/deck/sdtv/lib',
    'LIBVA_DRIVERS_PATH': '/usr/lib64/dri',
    'LIBVA_DRIVER_NAME': 'radeonsi',
    'LD_PRELOAD':
        '/home/deck/.local/share/Steam/ubuntu12_32/gameoverlayrenderer.so',
  };

  test('flatpak mpv gets no host driver or library paths', () {
    final env = ExternalMpvLauncher.childEnvironment(parent, flatpak: true);
    expect(env.containsKey('LIBVA_DRIVERS_PATH'), isFalse);
    expect(env.containsKey('LIBVA_DRIVER_NAME'), isFalse);
    expect(env.containsKey('LD_LIBRARY_PATH'), isFalse);
    expect(env.containsKey('LD_PRELOAD'), isFalse);
    expect(env['HOME'], '/home/deck');
  });

  test('system mpv keeps the host VA-API driver and system libs', () {
    final env = ExternalMpvLauncher.childEnvironment(parent, flatpak: false);
    expect(env['LIBVA_DRIVERS_PATH'], '/usr/lib64/dri');
    expect(env['LIBVA_DRIVER_NAME'], 'radeonsi');
    expect(env['LD_LIBRARY_PATH'], '/usr/lib64:/usr/lib');
    expect(env.containsKey('LD_PRELOAD'), isFalse);
  });

  test('steam overlay is stripped but other preloads stay', () {
    final env = ExternalMpvLauncher.childEnvironment({
      'LD_PRELOAD': '/opt/a.so:/x/gameoverlayrenderer.so',
    }, flatpak: false);
    expect(env['LD_PRELOAD'], '/opt/a.so');
  });
}
