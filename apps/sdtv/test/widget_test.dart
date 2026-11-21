import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_input/sdtv_input.dart';
import 'package:sdtv_player/sdtv_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdtv/app.dart';
import 'package:sdtv/services/screensaver_inhibitor.dart';
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
    // Footer controls render as key caps + actions.
    expect(find.text('X'), findsOneWidget);
    expect(find.text('hide'), findsOneWidget);
  });

  testWidgets('A on a live channel plays on mpv without asking', (
    tester,
  ) async {
    await _useWideSurface(tester);
    final mpv = _RecordingMpv();
    await _pumpDemo(tester, mpv: mpv);
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
    await _pumpUntilIdle(tester, () => mpv.plays.isNotEmpty);

    expect(mpv.plays, hasLength(1));
    expect(mpv.plays.single.vod, isFalse);
    expect(find.text('Play'), findsNothing);
    expect(find.text('mpv overlay'), findsNothing);
    // Let the live path's "mini guide once mpv is up" wait run out.
    await _pumpFor(tester, const Duration(seconds: 6));
  });

  testWidgets('Play Now on a movie plays on mpv', (tester) async {
    await _useWideSurface(tester);
    final mpv = _RecordingMpv();
    final session = await _pumpDemo(tester, mpv: mpv);
    await session.setGuideSection(GuideSection.movies);
    await _pumpUntil(tester, find.text('Demo Feature'));

    await tester.tap(find.text('Demo Feature'));
    await _pumpUntil(tester, find.text('Play Now'));
    await tester.tap(find.text('Play Now'));
    await _pumpUntilIdle(tester, () => mpv.plays.isNotEmpty);

    expect(mpv.plays, hasLength(1));
    expect(mpv.plays.single.vod, isTrue);
    expect(find.text('mpv overlay'), findsNothing);
  });

  testWidgets('episode Play Now and a file trailer play on mpv', (
    tester,
  ) async {
    await _useWideSurface(tester);
    final mpv = _RecordingMpv();
    final session = await _pumpDemo(tester, mpv: mpv);
    await session.setGuideSection(GuideSection.series);
    await _pumpUntil(tester, find.text('Harbor Nights'));

    await tester.tap(find.text('Harbor Nights'));
    await _pumpUntil(tester, find.text('Play Now'));
    await _pumpUntilIdle(
      tester,
      () => session.seriesCatalog != null && !session.vodDetailLoading,
    );
    await tester.tap(find.text('Play Now'));
    await _pumpUntilIdle(tester, () => mpv.plays.isNotEmpty);
    expect(mpv.plays.single.vod, isTrue);

    await _pumpUntil(tester, find.text('Watch trailer'));
    await tester.tap(find.text('Watch trailer'));
    await _pumpUntilIdle(tester, () => mpv.plays.length == 2);
    expect(mpv.plays, hasLength(2));
  });

  testWidgets('keys pressed in the mpv window drive sdtv', (tester) async {
    await _useWideSurface(tester);
    final mpv = _WatchingMpv();
    final session = await _pumpDemo(tester, mpv: mpv);
    expect(session.isWatchingExternal, isTrue);

    mpv.handleMpvEvent({
      'event': 'client-message',
      'args': ['sdtv-key', 'quit'],
    });
    await tester.pump();
    await _pumpUntilIdle(tester, () => mpv.quits > 0);
    expect(mpv.quits, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpFor(tester, const Duration(seconds: 6));
  });

  testWidgets('search page: rows by kind, keyboard moves through them', (
    tester,
  ) async {
    await _useWideSurface(tester);
    await _pumpDemo(tester);
    await _pumpUntil(tester, find.text('Entertainment'));

    _invoke(tester, find.text('CATEGORIES'), const SdtvSearchIntent());
    await _pumpUntil(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'o');
    await _pumpFor(tester, const Duration(milliseconds: 600));
    expect(find.textContaining('LIVE TV  ·'), findsOneWidget);
    expect(find.textContaining('MOVIES  ·'), findsOneWidget);
    expect(find.textContaining('TV SHOWS  ·'), findsOneWidget);

    String selected() {
      final cards = find.byWidgetPredicate((w) {
        final t = w.runtimeType.toString();
        return (t == '_ChannelCard' || t == '_PosterCard') &&
            (w as dynamic).selected == true;
      });
      if (cards.evaluate().isEmpty) return 'box';
      return ((cards.evaluate().first.widget as dynamic).hit as dynamic).title
          as String;
    }

    Future<void> press(LogicalKeyboardKey key) async {
      await _pastActivateCooldown(tester);
      await tester.sendKeyEvent(key);
      await tester.pump();
      await tester.pump();
    }

    expect(selected(), 'box');
    await press(LogicalKeyboardKey.arrowDown);
    final firstLive = selected();
    expect(firstLive, isNot('box'));
    await press(LogicalKeyboardKey.arrowRight);
    final secondLive = selected();
    expect(secondLive, isNot(firstLive));
    await press(LogicalKeyboardKey.arrowDown);
    final movie = selected();
    expect(movie, isNot(secondLive));
    // ↑ returns to the same Live card (each row keeps its column).
    await press(LogicalKeyboardKey.arrowUp);
    expect(selected(), secondLive);
    await press(LogicalKeyboardKey.arrowUp);
    expect(selected(), 'box');
  });

  testWidgets('↑ on the first menu row wraps to Exit sdtv', (tester) async {
    await _useWideSurface(tester);
    await _pumpDemo(tester);
    await _pumpUntil(tester, find.text('Entertainment'));

    _invoke(tester, find.text('CATEGORIES'), const SdtvMenuIntent());
    await _pumpUntil(tester, find.text('Exit sdtv'));
    String selected() => _focusedMenuRow();

    expect(selected(), 'Search');
    await _pastActivateCooldown(tester);
    _invoke(
      tester,
      find.text('Exit sdtv'),
      const DirectionalFocusIntent(TraversalDirection.up),
    );
    await tester.pump();
    expect(selected(), 'Exit sdtv');
    await _pastActivateCooldown(tester);
    _invoke(
      tester,
      find.text('Exit sdtv'),
      const DirectionalFocusIntent(TraversalDirection.down),
    );
    await tester.pump();
    expect(selected(), 'Search');
  });

  testWidgets('Last ch flips between the last two channels', (tester) async {
    await _useWideSurface(tester);
    final mpv = _PlayingMpv();
    final session = await _pumpDemo(tester, mpv: mpv);
    final chans = session.channelsInCategory;
    expect(chans.length, greaterThanOrEqualTo(2));

    unawaited(session.watchChannel(chans[0]));
    await tester.pump();
    expect(session.nowPlaying?.streamId, chans[0].streamId);
    expect(session.hasLastChannel, isFalse);

    await session.watchChannelAdjacent(1);
    expect(session.nowPlaying?.streamId, chans[1].streamId);
    expect(session.hasLastChannel, isTrue);

    await _pastActivateCooldown(tester); // zap debounce is wall-clock
    await session.watchLastChannel();
    expect(session.nowPlaying?.streamId, chans[0].streamId);

    await _pastActivateCooldown(tester);
    await session.watchLastChannel();
    expect(session.nowPlaying?.streamId, chans[1].streamId);

    mpv.finish();
    await _pumpFor(tester, const Duration(seconds: 6));
  });

  testWidgets('Next ep plays the following episode, across seasons', (
    tester,
  ) async {
    await _useWideSurface(tester);
    final mpv = _PlayingMpv();
    final session = await _pumpDemo(tester, mpv: mpv);
    await session.setGuideSection(GuideSection.series);
    await _pumpUntil(tester, find.text('Harbor Nights'));
    final show = session.seriesInCategory.firstWhere(
      (s) => s.name == 'Harbor Nights',
    );
    await tester.runAsync(() => session.openSeriesDetail(show));
    await _pumpUntilIdle(tester, () => session.seriesCatalog != null);
    final first = session.seriesCatalog!.firstEpisode!;

    unawaited(session.watchSeriesEpisode(show, first, fromBeginning: true));
    await tester.pump();
    expect(session.nowPlayingEpisode?.title, 'Pilot');
    expect(session.nextEpisode?.title, 'Fog Line');

    await session.watchNextEpisode();
    expect(session.nowPlayingEpisode?.title, 'Fog Line');
    expect(session.nextEpisode?.season, 2); // S2E1 comes next

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 5)),
    ); // advance debounce is wall-clock
    await session.watchNextEpisode();
    expect(session.nowPlayingEpisode?.title, 'Low Tide');
    expect(mpv.loads.length, 3);

    mpv.finish();
    await _pumpFor(tester, const Duration(seconds: 6));
  });

  testWidgets('screensaver is held while playing, not while paused or after', (
    tester,
  ) async {
    await _useWideSurface(tester);
    final mpv = _PlayingMpv();
    final saver = _RecordingInhibitor();
    final session = await _pumpDemo(tester, mpv: mpv, screensaver: saver);
    expect(saver.states, isEmpty); // guide only

    unawaited(session.watchChannel(session.channelsInCategory.first));
    await tester.pump();
    expect(saver.states, [true]);

    void pause(bool paused) => mpv.handleMpvEvent({
      'event': 'property-change',
      'name': 'pause',
      'data': paused,
    });
    pause(true);
    await tester.pump(); // stream events arrive on a microtask
    expect(saver.states, [true, false]);
    pause(false);
    await tester.pump();
    expect(saver.states, [true, false, true]);

    mpv.finish();
    await _pumpFor(tester, const Duration(seconds: 6));
    expect(saver.states.last, isFalse); // back in the guide
  });

  testWidgets('B on the error card closes it and keeps playing', (
    tester,
  ) async {
    await _useWideSurface(tester);
    final mpv = _PlayingMpv();
    final session = await _pumpDemo(tester, mpv: mpv);
    unawaited(session.watchChannel(session.channelsInCategory.first));
    await tester.pump();

    await mpv.showPlaybackError(channelName: 'x');
    expect(session.watchStallOpen, isTrue);

    await session.watchBack();
    expect(session.watchStallOpen, isFalse);
    expect(session.isWatchingExternal, isTrue); // still playing, not quit

    mpv.finish();
    await _pumpFor(tester, const Duration(seconds: 6));
  });

  testWidgets('the error card closes itself once playback moves again', (
    tester,
  ) async {
    await _useWideSurface(tester);
    final mpv = _PlayingMpv();
    final session = await _pumpDemo(tester, mpv: mpv);
    unawaited(session.watchChannel(session.channelsInCategory.first));
    await tester.pump();
    await mpv.showPlaybackError(channelName: 'x');
    expect(session.watchStallOpen, isTrue);

    // The stall watch polls every second; the clock moves 1s per poll.
    for (var t = 10.0; t <= 14 && session.watchStallOpen; t++) {
      mpv.position = t;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    }
    expect(session.watchStallOpen, isFalse);
    expect(session.isWatchingExternal, isTrue);

    mpv.finish();
    await _pumpFor(tester, const Duration(seconds: 6));
  });

  testWidgets('LB/RB cycle Live, Movies and TV Shows', (tester) async {
    await _useWideSurface(tester);
    final session = await _pumpDemo(tester);
    expect(session.guideSection, GuideSection.live);

    Future<void> bumper(Intent intent) async {
      await _pastActivateCooldown(tester);
      _invoke(tester, find.byType(Scaffold).last, intent);
      await _pumpFor(tester, const Duration(milliseconds: 300));
    }

    await bumper(const SdtvPageDownIntent());
    expect(session.guideSection, GuideSection.movies);
    await bumper(const SdtvPageDownIntent());
    expect(session.guideSection, GuideSection.series);
    await bumper(const SdtvPageDownIntent());
    expect(session.guideSection, GuideSection.live); // wraps
    await bumper(const SdtvPageUpIntent());
    expect(session.guideSection, GuideSection.series);
  });

  testWidgets('Manage categories: move a category up, hide one, B back', (
    tester,
  ) async {
    await _useWideSurface(tester);
    final session = await _pumpDemo(tester);
    List<String> guideCats() => [
      for (final c in session.browseCategories) c.categoryName,
    ];
    expect(guideCats(), ['★ Favorites', 'Entertainment', 'News', 'Sports']);

    Future<void> press(Intent intent) async {
      await _pastActivateCooldown(tester);
      final target = find.text('Manage categories').evaluate().isNotEmpty
          ? find.text('Manage categories').first
          : find.byType(Scaffold).last;
      _invoke(tester, target, intent);
      await tester.pump();
    }

    // ☰ → Settings → Manage categories (second row).
    _invoke(tester, find.byType(Scaffold).last, const SdtvMenuIntent());
    await _pumpUntil(tester, find.text('Exit sdtv'));
    await press(const DirectionalFocusIntent(TraversalDirection.down));
    await press(const SdtvConfirmIntent());
    await _pumpUntil(tester, find.text('Switch playlist'));
    await press(const DirectionalFocusIntent(TraversalDirection.down));
    await press(const SdtvConfirmIntent());
    await _pumpUntil(tester, find.textContaining('A move'));
    expect(find.text('Sports'), findsWidgets);

    // Sports: ↓↓, A picks it up, ↑↑ moves it to the top, A drops it.
    await press(const DirectionalFocusIntent(TraversalDirection.down));
    await press(const DirectionalFocusIntent(TraversalDirection.down));
    await press(const SdtvConfirmIntent());
    expect(find.textContaining('A / B drop'), findsOneWidget);
    await press(const DirectionalFocusIntent(TraversalDirection.up));
    await press(const DirectionalFocusIntent(TraversalDirection.up));
    await press(const SdtvConfirmIntent());
    expect(find.textContaining('A move'), findsOneWidget);
    expect(guideCats(), ['★ Favorites', 'Sports', 'Entertainment', 'News']);

    // X hides the focused one (Sports, still focused at the top).
    await press(const SdtvMuteIntent());
    await _pumpFor(tester, const Duration(milliseconds: 100));
    expect(find.text('Hidden'), findsOneWidget);
    expect(guideCats(), ['★ Favorites', 'Entertainment', 'News']);

    // The order is saved for this playlist.
    final settings = await SettingsStore.open();
    expect(settings.categoryOrder(session.prefsScope), ['3', '1', '2']);

    // B leaves Manage categories for Settings, not the guide.
    await press(const SdtvBackIntent());
    expect(find.textContaining('A move'), findsNothing);
    expect(find.text('Switch playlist'), findsOneWidget);
    await _pumpFor(tester, const Duration(seconds: 5));
  });

  testWidgets('☰ holds the essentials; Settings holds the rest', (
    tester,
  ) async {
    await _useWideSurface(tester);
    final session = await _pumpDemo(tester);
    await session.setGuideSection(GuideSection.movies);
    await _pumpUntil(tester, find.text('Demo Feature'));

    _invoke(tester, find.text('Demo Feature'), const SdtvMenuIntent());
    await _pumpUntil(tester, find.text('Exit sdtv'));
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Sign out'), findsNothing);
    expect(find.text('Switch playlist'), findsNothing);
    expect(
      find.textContaining('Hide'),
      findsNothing,
    ); // Movies: nothing to hide

    Future<void> press(Intent intent) async {
      await _pastActivateCooldown(tester);
      _invoke(
        tester,
        find.text('Exit sdtv').evaluate().isNotEmpty
            ? find.text('Exit sdtv')
            : find.text('About sdtv'),
        intent,
      );
      await tester.pump();
    }

    await press(const DirectionalFocusIntent(TraversalDirection.down));
    expect(_focusedMenuRow(), 'Settings');
    await press(const SdtvConfirmIntent());
    await _pumpUntil(tester, find.text('Manage categories'));
    for (final row in [
      'Switch playlist',
      'Manage categories',
      'About sdtv',
      'Sign out',
    ]) {
      expect(find.text(row), findsOneWidget, reason: row);
    }

    // Sign out: the first A only arms it.
    for (var i = 0; i < 3; i++) {
      await press(const DirectionalFocusIntent(TraversalDirection.down));
    }
    expect(_focusedMenuRow(), 'Sign out');
    await press(const SdtvConfirmIntent());
    expect(find.text('Press A again to sign out'), findsOneWidget);
    expect(session.phase, isNot(SessionPhase.login));

    // B leaves Settings.
    await press(const SdtvBackIntent());
    expect(find.text('Manage categories'), findsNothing);
    await _pumpFor(tester, const Duration(seconds: 5));
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

/// mpv that "plays" until [finish]: playFullscreen stays pending, loads are
/// recorded, and every stream reports healthy.
class _PlayingMpv extends ExternalMpvLauncher {
  final _done = Completer<ExternalMpvResult>();
  final loads = <Uri>[];
  bool _running = false;

  @override
  bool get isRunning => _running;

  @override
  Future<ExternalMpvResult> playFullscreen(
    Uri url, {
    List<({String title, Uri uri})>? playlist,
    int startIndex = 0,
    Uri? fallbackUrl,
    String? fallbackTitle,
    bool vod = false,
    Duration? startAt,
  }) {
    _running = true;
    loads.add(url);
    return _done.future;
  }

  @override
  Future<bool> loadFile(Uri url, {String? title}) async {
    loads.add(url);
    return true;
  }

  @override
  Future<bool> ensureHealthyOrShowError(
    Uri? fallback, {
    String? title,
    Duration timeout = ExternalMpvLauncher.startTimeout,
  }) async => true;

  @override
  Future<bool> sendCommand(List<Object?> command) async => true;

  /// Play position mpv reports (null: none yet).
  double? position;

  @override
  Future<Object?> getProperty(String name) async =>
      name == 'time-pos' ? position : null;

  void finish() {
    _running = false;
    _done.complete(
      const ExternalMpvResult(started: true, durationMs: 60000, userQuit: true),
    );
  }
}

class _RecordingInhibitor implements ScreenSaverInhibitor {
  final states = <bool>[];

  @override
  Future<void> setActive(bool active) async => states.add(active);

  @override
  Future<void> dispose() async {}
}

/// Reports a running mpv (so the page is in watch mode) without a process.
class _WatchingMpv extends ExternalMpvLauncher {
  int quits = 0;

  @override
  bool get isRunning => true;

  @override
  Future<void> quit() async => quits++;
}

/// Records plays instead of spawning mpv, and reports an immediate user quit.
class _RecordingMpv extends ExternalMpvLauncher {
  final plays = <({Uri url, bool vod})>[];

  @override
  Future<ExternalMpvResult> playFullscreen(
    Uri url, {
    List<({String title, Uri uri})>? playlist,
    int startIndex = 0,
    Uri? fallbackUrl,
    String? fallbackTitle,
    bool vod = false,
    Duration? startAt,
  }) async {
    plays.add((url: url, vod: vod));
    return const ExternalMpvResult(
      started: true,
      exitCode: 0,
      durationMs: 60000,
      userQuit: true,
    );
  }
}

Future<SessionController> _pumpDemo(
  WidgetTester tester, {
  ExternalMpvLauncher? mpv,
  ScreenSaverInhibitor? screensaver,
}) async {
  final settings = await SettingsStore.open();
  final session = SessionController(
    settings: settings,
    externalMpv: mpv,
    screensaver: screensaver,
  );
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

/// Title of the focused row in the ☰ menu or Settings.
String _focusedMenuRow() {
  final rows = find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_Row' && (w as dynamic).focused == true,
  );
  return ((rows.evaluate().first.widget as dynamic).entry as dynamic).title
      as String;
}
