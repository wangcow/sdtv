import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_input/sdtv_input.dart';

void main() {
  bool passes(GamepadEdge e, {required bool keyboard}) =>
      SdtvGamepadBinding.passesWhileTyping(e, fromKeyboard: keyboard);

  test(
    'while typing, the pad D-pad and A stay with the on-screen keyboard',
    () {
      for (final e in [
        GamepadEdge.up,
        GamepadEdge.down,
        GamepadEdge.left,
        GamepadEdge.right,
        GamepadEdge.confirm,
        GamepadEdge.favorite,
        GamepadEdge.mute,
        GamepadEdge.pageUp,
        GamepadEdge.pageDown,
        GamepadEdge.menu,
      ]) {
        expect(passes(e, keyboard: false), isFalse, reason: '$e from the pad');
      }
    },
  );

  test('B leaves the field from either; ↓ only from a real keyboard', () {
    expect(passes(GamepadEdge.back, keyboard: false), isTrue);
    expect(passes(GamepadEdge.back, keyboard: true), isTrue);
    expect(passes(GamepadEdge.down, keyboard: true), isTrue);
    expect(passes(GamepadEdge.down, keyboard: false), isFalse);
    expect(passes(GamepadEdge.up, keyboard: true), isFalse);
  });
}
