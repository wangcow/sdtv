import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv/main.dart';

void main() {
  testWidgets('playground shows branding and categories', (tester) async {
    await tester.pumpWidget(const SdtvApp());
    await tester.pumpAndSettle();

    expect(find.text('sdtv'), findsOneWidget);
    expect(find.text('Product of the Wangcow Corporation'), findsOneWidget);
    expect(find.text('Entertainment'), findsOneWidget);
    expect(find.textContaining('CONTROLLER PLAYGROUND'), findsOneWidget);
  });
}
