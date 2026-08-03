import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_input/sdtv_input.dart';

void main() {
  test('Xbox / Deck button map: A/B/menu/shoulders', () {
    expect(LinuxJoystickReader.mapButton(0), GamepadEdge.confirm);
    expect(LinuxJoystickReader.mapButton(1), GamepadEdge.back);
    expect(LinuxJoystickReader.mapButton(3), GamepadEdge.menu); // Y
    expect(LinuxJoystickReader.mapButton(4), GamepadEdge.pageUp);
    expect(LinuxJoystickReader.mapButton(5), GamepadEdge.pageDown);
    expect(LinuxJoystickReader.mapButton(6), GamepadEdge.menu); // Select/View
    expect(LinuxJoystickReader.mapButton(7), GamepadEdge.menu); // Start/Options
    expect(LinuxJoystickReader.mapButton(2), isNull); // X unused for now
  });
}
