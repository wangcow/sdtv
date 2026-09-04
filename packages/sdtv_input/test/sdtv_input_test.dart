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

  test('button map summary covers guide and watch', () {
    expect(SdtvButtonMap.summary, contains('pause'));
    expect(SdtvButtonMap.summary, contains('volume'));
  });

  testWidgets('letter and Enter shortcuts do not fire while typing',
      (tester) async {
    var confirmed = 0;
    var muted = 0;
    var favored = 0;
    final field = FocusNode();
    final host = FocusNode();
    addTearDown(field.dispose);
    addTearDown(host.dispose);
    SdtvTextFocusRegistry.register(field);
    addTearDown(() => SdtvTextFocusRegistry.unregister(field));

    await tester.pumpWidget(
      MaterialApp(
        home: SdtvInputScope(
          onConfirm: () => confirmed++,
          onMute: () => muted++,
          onFavorite: () => favored++,
          child: Focus(
            focusNode: host,
            child: Scaffold(
              body: TextField(focusNode: field),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    field.requestFocus();
    await tester.pump();
    expect(SdtvTextFocusRegistry.primaryIsTextField, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();

    expect(confirmed, 0);
    expect(muted, 0);
    expect(favored, 0);

    host.requestFocus();
    await tester.pump();
    expect(SdtvTextFocusRegistry.primaryIsTextField, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(confirmed, 1);
    expect(muted, 1);
  });
}
