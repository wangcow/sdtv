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
  Future<Duration> position() async => Duration.zero;

  @override
  Future<Duration> length() async => Duration.zero;

  @override
  Future<bool> paused() async => false;
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

    expect(find.text('Live · LB/RB channel · ←→ chrome'), findsOneWidget);
    expect(find.text('mpv · vo=gpu'), findsOneWidget);
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
}
