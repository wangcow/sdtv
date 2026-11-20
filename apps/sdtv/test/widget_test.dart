import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_input/sdtv_input.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdtv/app.dart';
import 'package:sdtv/services/settings_store.dart';
import 'package:sdtv/state/session_controller.dart';
import 'package:sdtv/ui/widgets/vod_poster_tile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Asset futures are cached on the process-wide bundle. A future completed
    // in a previous test's fake clock never resumes in the next test, so the
    // second demo connect sits on "loading" forever. Drop the cache and put
    // the fixture handler back (flutter_test clears mock handlers per test).
    rootBundle.clear();
    _installFixtureAssets();
  });

  testWidgets('login screen shows demo and branding', (tester) async {
    await _useWideSurface(tester);
    final settings = await SettingsStore.open();
    final session = SessionController(settings: settings);
    await tester.pumpWidget(SdtvApp(session: session));
    await _pumpFor(tester, const Duration(milliseconds: 400));

    expect(find.text('sdtv'), findsWidgets);
    expect(find.text('Continue with demo playlist'), findsOneWidget);
    expect(find.text('Product of the Wangcow Corporation'), findsOneWidget);
  });

  testWidgets('demo connect reaches live browse', (tester) async {
    await _useWideSurface(tester);
    final settings = await SettingsStore.open();
    final session = SessionController(settings: settings);
    await tester.pumpWidget(SdtvApp(session: session));
    await _pumpFor(tester, const Duration(milliseconds: 400));

    await tester.tap(find.text('Continue with demo playlist'));
    await _pumpFor(tester, const Duration(milliseconds: 400));

    expect(find.textContaining('CATEGORIES'), findsOneWidget);
    expect(find.text('Entertainment'), findsOneWidget);
    expect(find.textContaining('DEMO'), findsOneWidget);
  });

  testWidgets('live play asks which chrome to use', (tester) async {
    await _useWideSurface(tester);
    await _pumpDemo(tester);
    await _pumpUntil(tester, find.textContaining('Mock Entertainment 1'));

    // A on the category column enters the guide. A again plays. The second
    // press is ignored for 280ms of wall clock (DateTime, not the test clock).
    _invoke(tester, find.text('CATEGORIES'), const SdtvConfirmIntent());
    await tester.pump();
    await _pastActivateCooldown(tester);
    _invoke(
      tester,
      find.textContaining('Mock Entertainment 1').first,
      const SdtvConfirmIntent(),
    );
    await _pumpUntil(tester, find.text('Flutter chrome'));

    expect(find.text('Flutter chrome'), findsOneWidget);
    expect(find.text('mpv overlay'), findsOneWidget);
    expect(find.text('Mock Entertainment 1'), findsWidgets);
    expect(
      find.text('External mpv · Flutter HUD on the video'),
      findsOneWidget,
    );
    expect(
      find.text('Clean HUD on the embedded player (slow)'),
      findsOneWidget,
    );

    _invoke(tester, find.text('mpv overlay'), const SdtvBackIntent());
    await _pumpUntil(tester, find.text('Entertainment'));
    expect(find.text('mpv overlay'), findsNothing);
    expect(find.text('Flutter chrome'), findsNothing);
  });

  testWidgets('movie play asks, and Flutter chrome opens the HUD', (
    tester,
  ) async {
    await _useWideSurface(tester);
    final session = await _pumpDemo(tester);
    await session.setGuideSection(GuideSection.movies);
    await _pumpUntil(tester, find.text('Demo Feature'));

    await tester.tap(find.text('Demo Feature'));
    await _pumpUntil(tester, find.text('Play Now'));
    await tester.tap(find.text('Play Now'));
    await _pumpUntil(tester, find.text('Flutter chrome'));

    expect(find.text('Flutter chrome'), findsOneWidget);
    expect(find.text('mpv overlay'), findsOneWidget);
    expect(find.text('Demo Feature'), findsWidgets);

    await tester.tap(find.text('Flutter chrome'));
    await _pumpUntil(tester, find.text('On-demand · Flutter chrome'));

    expect(find.text('On-demand · Flutter chrome'), findsOneWidget);
    expect(find.text('mpv overlay'), findsNothing);
    expect(session.watchingVod, isTrue);

    await tester.tap(find.text('Back'));
    await _pumpUntil(tester, find.text('Play Now'));
    await _pumpUntilIdle(tester, () => !session.watchingVod);

    expect(find.text('Play Now'), findsOneWidget);
    expect(session.watchingVod, isFalse);
    expect(session.embeddedUri, isNull);
  });

  testWidgets('menu Flutter chrome plays the highlighted movie', (
    tester,
  ) async {
    await _useWideSurface(tester);
    final session = await _pumpDemo(tester);
    await session.setGuideSection(GuideSection.movies);
    await _pumpUntil(tester, find.text('Demo Feature'));

    _invoke(tester, find.text('Demo Feature'), const SdtvMenuIntent());
    await _pumpUntil(tester, find.text('Flutter chrome (slow)'));
    await tester.tap(find.text('Flutter chrome (slow)'));
    await _pumpUntil(tester, find.text('On-demand · Flutter chrome'));

    expect(find.text('mpv overlay'), findsNothing);
    expect(find.text('On-demand · Flutter chrome'), findsOneWidget);
    expect(find.text('Demo Feature'), findsWidgets);
    expect(session.isWatchingExternal, isFalse);

    await tester.tap(find.text('Back'));
    await _pumpUntil(tester, find.text('Demo Feature'));
    await _pumpUntilIdle(tester, () => session.embeddedUri == null);
  });

  testWidgets('episode play asks, file trailer asks', (tester) async {
    await _useWideSurface(tester);
    final session = await _pumpDemo(tester);
    await session.setGuideSection(GuideSection.series);
    await _pumpUntil(tester, find.text('Harbor Nights'));

    await tester.tap(find.text('Harbor Nights'));
    await _pumpUntil(tester, find.text('Play Now'));
    await _pumpUntilIdle(
      tester,
      () => session.seriesCatalog != null && !session.vodDetailLoading,
    );
    await tester.tap(find.text('Play Now'));
    await _pumpUntil(tester, find.text('Flutter chrome'));

    expect(find.text('Flutter chrome'), findsOneWidget);
    expect(find.textContaining('Harbor Nights'), findsWidgets);

    _invoke(tester, find.text('mpv overlay'), const SdtvBackIntent());
    await _pumpUntil(tester, find.text('Watch trailer'));

    await tester.tap(find.text('Watch trailer'));
    await _pumpUntil(tester, find.text('Flutter chrome'));
    expect(find.text('Flutter chrome'), findsOneWidget);
    expect(find.textContaining('trailer'), findsWidgets);
    expect(session.isWatchingExternal, isFalse);
  });

  testWidgets('finished movie poster dims and a finished episode row checks', (
    tester,
  ) async {
    await _useWideSurface(tester);
    SharedPreferences.setMockInitialValues({
      'user_library.v1': jsonEncode({
        'demo': {
          'v': 1,
          'favorites': <String>[],
          'progress': <String, int>{},
          'watched': ['v:9002', 'se:8102'],
          'seriesResume': <String, Map<String, String>>{},
        },
      }),
    });
    final session = await _pumpDemo(tester);
    await session.setGuideSection(GuideSection.movies);
    await _pumpUntil(tester, find.text('Another Title'));

    expect(
      find.descendant(
        of: find.widgetWithText(VodPosterTile, 'Another Title'),
        matching: find.byType(WatchedArtScrim),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.widgetWithText(VodPosterTile, 'Demo Feature'),
        matching: find.byType(WatchedArtScrim),
      ),
      findsNothing,
    );
    final watchedTitle = tester.widget<Text>(find.text('Another Title'));
    expect(watchedTitle.style?.color?.a ?? 1, lessThan(0.7));
    final scrim = tester.widget<WatchedArtScrim>(
      find.descendant(
        of: find.widgetWithText(VodPosterTile, 'Another Title'),
        matching: find.byType(WatchedArtScrim),
      ),
    );
    expect(scrim.lifted, isFalse);

    await session.setGuideSection(GuideSection.series);
    await _pumpUntil(tester, find.text('Harbor Nights'));
    await tester.tap(find.text('Harbor Nights'));
    await _pumpUntil(tester, find.text('Seasons & episodes'));
    await _pumpUntilIdle(
      tester,
      () => session.seriesCatalog != null && !session.vodDetailLoading,
    );
    await tester.tap(find.text('Seasons & episodes'));
    await _pumpUntil(tester, find.text('E2  Fog Line'));

    expect(find.textContaining('Watched'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline), findsWidgets);
    final played = tester.widget<Text>(find.text('E2  Fog Line'));
    expect(played.style?.color?.a ?? 1, lessThan(0.7));
    final fresh = tester.widget<Text>(find.text('E1  Pilot'));
    expect(fresh.style?.color?.a ?? 0, greaterThan(0.85));
  });
}

Future<void> _useWideSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

/// Advance the clock without [WidgetTester.pumpAndSettle]. The guide keeps a
/// 30s clock and short animations; settling until idle walks that clock.
Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  final step = const Duration(milliseconds: 50);
  var left = total;
  while (left > Duration.zero) {
    final slice = left < step ? left : step;
    await tester.pump(slice);
    left -= slice;
  }
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsWidgets);
}

Future<SessionController> _pumpDemo(WidgetTester tester) async {
  final settings = await SettingsStore.open();
  final session = SessionController(settings: settings);
  await tester.pumpWidget(SdtvApp(session: session));
  // Let bootstrap land on login before connectDemo, or a late bootstrap
  // notify can send the session back to the login phase.
  await _pumpUntil(tester, find.text('Continue with demo playlist'));
  final connect = session.connectDemo();
  await _pumpUntil(tester, find.text('Entertainment'));
  await connect;
  return session;
}

/// flutter_test serves fixture files from UNIT_TEST_ASSETS, then drops the
/// handler when the test ends. Put it back so later tests can load mocks.
void _installFixtureAssets() {
  final folder = Platform.environment['UNIT_TEST_ASSETS'];
  final appName = Platform.environment['APP_NAME'];
  if (folder == null || appName == null) return;
  final prefix = 'packages/$appName/';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (ByteData? message) {
        if (message == null) return null;
        var key = utf8.decode(message.buffer.asUint8List());
        var file = File('$folder/$key');
        if (!file.existsSync() && key.startsWith(prefix)) {
          key = key.substring(prefix.length);
          file = File('$folder/$key');
        }
        if (!file.existsSync()) return null;
        final encoded = Uint8List.fromList(file.readAsBytesSync());
        return SynchronousFuture<ByteData>(encoded.buffer.asByteData());
      });
}

/// Guide A is ignored for 280ms of real time. The widget clock does not
/// move [DateTime.now], so this wait has to leave the fake async zone.
Future<void> _pastActivateCooldown(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 320)),
  );
}

Future<void> _pumpUntilIdle(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 40; i++) {
    if (ready()) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue);
}

void _invoke(WidgetTester tester, Finder finder, Intent intent) {
  // CallbackAction.invoke returns null. A missing binding throws in debug.
  Actions.invoke(tester.element(finder), intent);
}
