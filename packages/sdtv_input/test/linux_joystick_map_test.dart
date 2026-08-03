import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_input/sdtv_input.dart';

void main() {
  test('Xbox button map: A/B/Start/shoulders', () {
    expect(LinuxJoystickReader.mapButton(0), GamepadEdge.confirm);
    expect(LinuxJoystickReader.mapButton(1), GamepadEdge.back);
    expect(LinuxJoystickReader.mapButton(4), GamepadEdge.pageUp);
    expect(LinuxJoystickReader.mapButton(5), GamepadEdge.pageDown);
    expect(LinuxJoystickReader.mapButton(7), GamepadEdge.menu);
    expect(LinuxJoystickReader.mapButton(2), isNull); // X unused for now
  });
}
