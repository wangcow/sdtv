import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdtv/services/settings_store.dart';
import 'package:sdtv/state/session_controller.dart';
import 'package:sdtv/theme.dart';
import 'package:sdtv/state/watch_menu.dart';
import 'package:sdtv/ui/widgets/mpv_flutter_hud.dart';
import 'package:sdtv/ui/widgets/watch_menu_card.dart';
import 'package:sdtv_player/sdtv_player.dart';

class _Band {
  _Band(this.rgba, this.x, this.y, this.w, this.h);
  final Uint8List rgba;
  final int x;
  final int y;
  final int w;
  final int h;

  int alphaAt(int px, int py) => rgba[py * w * 4 + px * 4 + 3];
}

class _FakeOverlay implements MpvBitmapOverlay {
  int pushes = 0;
  final Map<int, _Band> bands = {};
  final props = StreamController<({String name, Object? value})>.broadcast();

  @override
  bool broken = false;

  @override
  void activate() {}

  @override
  void deactivate() {}

  @override
  void markBroken() {
    broken = true;
  }

  @override
  Future<({int w, int h})?> readOsdSize() async => null;

  @override
  Future<bool> pushBand(
    Uint8List rgba, {
    required int id,
    required int x,
    required int y,
    required int width,
    required int height,
  }) async {
    pushes++;
    bands[id] = _Band(Uint8List.fromList(rgba), x, y, width, height);
    return true;
  }

  @override
  Stream<({String name, Object? value})> get propertyChanges => props.stream;

  @override
  Future<void> clear() async => bands.clear();

  @override
  Future<void> removeBand(int id) async => bands.remove(id);

  @override
  Future<Duration> position() async => Duration.zero;

  @override
  Future<Duration> length() async => Duration.zero;

  @override
  Future<bool> paused() async => false;

  int subtitleCycles = 0;

  @override
  Future<HudStreamInfo> streamInfo() async => const HudStreamInfo(
    subtitles: 'Off',
    audio: 'English',
    height: 1080,
    hardwareDecode: true,
  );

  @override
  Future<void> cycleSubtitles() async => subtitleCycles++;

  @override
  Future<void> cycleAudio() async {}
}

/// Reports a running mpv so watch menus open; every IPC call is a no-op.
class _RunningMpv extends ExternalMpvLauncher {
  final texts = <String>[];

  @override
  bool get isRunning => true;

  @override
  Future<void> showText(String text, {int durationMs = 2000}) async {
    texts.add(text);
  }
}

Future<void> _settle(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 8 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pump();
  }
}

void main() {
  testWidgets('HUD sends only the top and bottom bands, edge-anchored', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await SettingsStore.open();
    final session = SessionController(settings: settings);
    final fake = _FakeOverlay();
    final key = GlobalKey<MpvFlutterHudState>();
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: sdtvDarkTheme,
        home: Scaffold(
          body: MpvFlutterHud(
            key: key,
            session: session,
            overlay: fake,
            capturePixelRatio: 1,
          ),
        ),
      ),
    );
    await tester.pump();
    // Each band's toImage completes in its own real-async window.
    for (var i = 0; i < 4 && fake.bands.length < 2; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump();
    }

    // TiviMate-style live row and stream facts.
    for (final label in ['Prev ch', 'Pause', 'Next ch', 'CC · Off', 'Guide']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('English'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
    expect(find.text('HW'), findsOneWidget);
    expect(fake.pushes, greaterThanOrEqualTo(2));
    final top = fake.bands[ExternalMpvLauncher.bitmapOverlayId]!;
    final bottom = fake.bands[ExternalMpvLauncher.bitmapOverlayIdBottom]!;

    // Full width, pinned to the top and bottom edges of a 1280x720 OSD.
    expect(top.x, 0);
    expect(top.y, 0);
    expect(top.w, 1280);
    expect(bottom.x, 0);
    expect(bottom.w, 1280);
    expect(bottom.y + bottom.h, 720);

    // The clear middle of the picture is never sent.
    expect(top.h + bottom.h, lessThan(720 * 0.6));
    expect(top.y + top.h, lessThanOrEqualTo(bottom.y));

    // Solid scrim at the outer edges, clear at the inner edges.
    expect(top.alphaAt(8, 2), greaterThan(150));
    expect(top.alphaAt(8, top.h - 1), lessThan(16));
    expect(bottom.alphaAt(8, bottom.h - 1), greaterThan(150));
    expect(bottom.alphaAt(8, 0), lessThan(16));

    expect(key.currentState!.handleBack(), isTrue);
    expect(key.currentState!.handleBack(), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('pause menu replaces the chrome bands with one centered card', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await SettingsStore.open();
    final session = SessionController(
      settings: settings,
      externalMpv: _RunningMpv(),
    );
    final fake = _FakeOverlay();
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: sdtvDarkTheme,
        home: Scaffold(
          body: MpvFlutterHud(
            session: session,
            overlay: fake,
            capturePixelRatio: 1,
          ),
        ),
      ),
    );
    await _settle(tester, () => fake.bands.length >= 2);
    expect(fake.bands.keys, contains(ExternalMpvLauncher.bitmapOverlayId));

    await tester.runAsync(session.watchOpenMenu);
    await tester.pump();
    await _settle(
      tester,
      () => fake.bands.containsKey(ExternalMpvLauncher.bitmapOverlayIdMenu),
    );

    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Back to guide'), findsOneWidget);
    expect(fake.bands.keys, [ExternalMpvLauncher.bitmapOverlayIdMenu]);
    final card = fake.bands[ExternalMpvLauncher.bitmapOverlayIdMenu]!;
    // Centered and much smaller than the screen.
    expect((card.x + card.w / 2 - 640).abs(), lessThan(2));
    expect((card.y + card.h / 2 - 360).abs(), lessThan(2));
    expect(card.w * card.h, lessThan(1280 * 720 * 0.4));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('stall card shows the error code, message, and actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: sdtvDarkTheme,
        home: const Scaffold(
          body: Center(
            child: WatchMenuCard(
              model: WatchMenuModel(
                title: '101. Mock Entertainment 1',
                errorCode: 'A-HOLD',
                errorMessage: 'Playback stopped',
                selected: 0,
                hint: 'A select  ·  B guide',
                rows: [
                  WatchMenuRow('retry', 'Retry'),
                  WatchMenuRow('guide', 'Back to guide'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('A-HOLD'), findsOneWidget);
    expect(find.text('Playback stopped'), findsOneWidget);
    expect(find.text('101. Mock Entertainment 1'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
  });

  test('a playback error opens the error menu instead of mpv text', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await SettingsStore.open();
    final mpv = _RunningMpv();
    final session = SessionController(settings: settings, externalMpv: mpv);
    mpv.playbackBitmapHud = true; // as when MpvFlutterHud is on screen

    await mpv.showPlaybackError(channelName: '101. Mock Entertainment 1');

    expect(mpv.texts, isEmpty);
    expect(session.watchStallOpen, isTrue);
    final menu = session.watchMenuModel!;
    expect(menu.isError, isTrue);
    expect(menu.errorCode, isNotEmpty);
    expect([for (final r in menu.rows) r.id], ['retry', 'guide']);
    expect(menu.hint, contains('LB/RB'));
  });

  testWidgets('→ → from Play reaches Subtitles, and A cycles the track', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await SettingsStore.open();
    final session = SessionController(settings: settings);
    final fake = _FakeOverlay();
    final key = GlobalKey<MpvFlutterHudState>();
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: sdtvDarkTheme,
        home: Scaffold(
          body: MpvFlutterHud(
            key: key,
            session: session,
            overlay: fake,
            capturePixelRatio: 1,
          ),
        ),
      ),
    );
    await tester.pump();

    key.currentState!
      ..horizontal(1)
      ..horizontal(1)
      ..confirm();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(fake.subtitleCycles, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  test('with the HUD up, messages become toasts instead of mpv text', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await SettingsStore.open();
    final mpv = _CommandMpv();
    final session = SessionController(settings: settings, externalMpv: mpv);
    mpv.playbackBitmapHud = true; // as when MpvFlutterHud is on screen

    await mpv.showText('Retrying…', durationMs: 1500);
    expect(session.hudToast?.text, 'Retrying…');
    expect(session.hudToast?.icon, 'retry');

    await mpv.addVolume(5);
    expect(mpv.commands.first, ['add', 'volume', 5]); // no mpv volume bar
    expect(session.hudToast?.text, 'Volume +');
    expect(mpv.commands.any((c) => c.first == 'show-text'), isFalse);
    session.dispose();
  });

  testWidgets('a toast shows with the controls hidden and leaves on expiry', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await SettingsStore.open();
    final session = SessionController(settings: settings);
    final fake = _FakeOverlay();
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: sdtvDarkTheme,
        home: Scaffold(
          body: MpvFlutterHud(
            session: session,
            overlay: fake,
            capturePixelRatio: 1,
          ),
        ),
      ),
    );
    // Let the controls auto-hide.
    await tester.pump(const Duration(seconds: 5));
    await _settle(tester, () => false);
    expect(
      fake.bands.containsKey(ExternalMpvLauncher.bitmapOverlayId),
      isFalse,
    );

    session.externalMpv.playbackBitmapHud = true;
    session.externalMpv.onToast!(
      'Volume 40',
      durationMs: 1200,
      level: 0.4,
      icon: 'volume',
    );
    await tester.pump();
    await _settle(
      tester,
      () => fake.bands.containsKey(ExternalMpvLauncher.bitmapOverlayIdToast),
    );
    expect(find.text('Volume 40'), findsOneWidget);
    expect(fake.bands.keys, [ExternalMpvLauncher.bitmapOverlayIdToast]);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('Volume 40'), findsNothing);
    expect(
      fake.bands.containsKey(ExternalMpvLauncher.bitmapOverlayIdToast),
      isFalse,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

/// Records IPC commands instead of talking to mpv.
class _CommandMpv extends ExternalMpvLauncher {
  final commands = <List<Object?>>[];

  @override
  bool get isRunning => true;

  @override
  Future<bool> sendCommand(List<Object?> command) async {
    commands.add(command);
    return true;
  }
}
