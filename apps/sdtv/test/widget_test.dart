import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdtv/app.dart';
import 'package:sdtv/services/settings_store.dart';
import 'package:sdtv/state/session_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('login screen shows demo and branding', (tester) async {
    final settings = await SettingsStore.open();
    final session = SessionController(settings: settings);
    await tester.pumpWidget(SdtvApp(session: session));
    await tester.pumpAndSettle();

    expect(find.text('sdtv'), findsWidgets);
    expect(find.text('Continue with demo playlist'), findsOneWidget);
    expect(find.text('Product of the Wangcow Corporation'), findsOneWidget);
  });

  testWidgets('demo connect reaches live browse', (tester) async {
    final settings = await SettingsStore.open();
    final session = SessionController(settings: settings);
    await tester.pumpWidget(SdtvApp(session: session));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue with demo playlist'));
    await tester.pumpAndSettle();

    expect(find.textContaining('CATEGORIES'), findsOneWidget);
    expect(find.text('Entertainment'), findsOneWidget);
    expect(find.textContaining('DEMO'), findsOneWidget);
  });
}
