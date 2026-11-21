import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_input/sdtv_input.dart';

void main() {
  test('Xbox / Deck button map: A/B/X mute/Y favorite/menu/shoulders', () {
    expect(LinuxJoystickReader.mapButton(0), GamepadEdge.confirm);
    expect(LinuxJoystickReader.mapButton(1), GamepadEdge.back);
    expect(LinuxJoystickReader.mapButton(2), GamepadEdge.mute); // X
    expect(LinuxJoystickReader.mapButton(3), GamepadEdge.favorite); // Y
    expect(LinuxJoystickReader.mapButton(4), GamepadEdge.pageUp);
    expect(LinuxJoystickReader.mapButton(5), GamepadEdge.pageDown);
    expect(LinuxJoystickReader.mapButton(6), GamepadEdge.menu); // Select/View
    expect(LinuxJoystickReader.mapButton(7), GamepadEdge.menu); // Start/Options
  });

  test('listDevicePaths is sorted and only jsN names', () {
    final paths = LinuxJoystickReader.listDevicePaths();
    for (final p in paths) {
      expect(p, contains('/dev/input/js'));
      expect(RegExp(r'js\d+$').hasMatch(p), isTrue);
    }
    // Sorted by index when multiple exist (empty list is fine on CI).
    for (var i = 1; i < paths.length; i++) {
      final a = int.parse(
        RegExp(r'js(\d+)$').firstMatch(paths[i - 1])!.group(1)!,
      );
      final b = int.parse(RegExp(r'js(\d+)$').firstMatch(paths[i])!.group(1)!);
      expect(a, lessThanOrEqualTo(b));
    }
  });

  test('with Steam Input running, only its virtual pads are read', () {
    // The Deck in Game Mode with a Bluetooth Xbox pad (seen on a real Deck).
    const ids = {
      '/dev/input/js0': '28de:11ff', // Steam virtual pad (Deck controls)
      '/dev/input/js1': '045e:0b13', // the Xbox pad itself, raw
      '/dev/input/js2': '28de:11ff', // Steam virtual pad (Xbox pad)
    };
    expect(
      LinuxJoystickReader.preferSteamVirtualPads(
        ids.keys.toList(),
        (p) => ids[p],
      ),
      ['/dev/input/js0', '/dev/input/js2'],
    );
  });

  test('without Steam Input every controller is read', () {
    const ids = {'/dev/input/js0': '045e:0b13', '/dev/input/js1': null};
    expect(
      LinuxJoystickReader.preferSteamVirtualPads(
        ids.keys.toList(),
        (p) => ids[p],
      ),
      ['/dev/input/js0', '/dev/input/js1'],
    );
  });
}
