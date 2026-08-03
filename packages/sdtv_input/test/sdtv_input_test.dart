import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_input/sdtv_input.dart';

void main() {
  testWidgets('arrow keys move focus between tiles', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SdtvInputScope(
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: const Scaffold(
              body: Column(
                children: [
                  SdtvFocusTile(label: 'One', autofocus: true),
                  SdtvFocusTile(label: 'Two'),
                  SdtvFocusTile(label: 'Three'),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // First tile should be focused via autofocus.
    final first = tester.widget<Focus>(
      find.descendant(
        of: find.widgetWithText(SdtvFocusTile, 'One'),
        matching: find.byType(Focus),
      ),
    );
    expect(first.focusNode?.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    final second = tester.widget<Focus>(
      find.descendant(
        of: find.widgetWithText(SdtvFocusTile, 'Two'),
        matching: find.byType(Focus),
      ),
    );
    expect(second.focusNode?.hasFocus, isTrue);
  });

  test('button map summary is non-empty', () {
    expect(SdtvButtonMap.summary, contains('Confirm'));
  });
}
