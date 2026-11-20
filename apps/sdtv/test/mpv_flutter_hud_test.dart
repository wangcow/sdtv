import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdtv/services/settings_store.dart';
import 'package:sdtv/state/session_controller.dart';
import 'package:sdtv/theme.dart';
import 'package:sdtv/ui/widgets/mpv_flutter_hud.dart';

class _FakeOverlay implements MpvBitmapOverlay {
  int pushes = 0;
  Uint8List? rgba;
  int w = 0;
  int h = 0;

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
  Future<bool> pushRgba(
    Uint8List rgba, {
    required int width,
    required int height,
    int? displayWidth,
    int? displayHeight,
  }) async {
    pushes++;
    this.rgba = Uint8List.fromList(rgba);
    w = width;
    h = height;
    return true;
  }

  @override
  Future<void> clear() async {}

  @override
  Future<Duration> position() async => Duration.zero;

  @override
  Future<Duration> length() async => Duration.zero;

  @override
  Future<bool> paused() async => false;
}

void main() {
  testWidgets('HUD bitmap keeps a clear center and a solid top scrim', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await SettingsStore.open();
    final session = SessionController(settings: settings);
    final fake = _FakeOverlay();
    final key = GlobalKey<MpvFlutterHudState>();
    await tester.binding.setSurfaceSize(const Size(640, 360));
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
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pump();

    expect(find.text('Live · LB/RB channel · ←→ chrome'), findsOneWidget);
    expect(find.text('mpv · vo=gpu'), findsOneWidget);
    expect(fake.pushes, greaterThan(0));
    expect(fake.w, greaterThan(200));
    expect(fake.h, greaterThan(120));
    final bytes = fake.rgba!;
    final stride = fake.w * 4;
    int alphaAt(int x, int y) => bytes[y * stride + x * 4 + 3];
    expect(alphaAt(8, 2), greaterThan(80));
    expect(alphaAt(fake.w ~/ 2, fake.h ~/ 2), 0);

    expect(key.currentState!.handleBack(), isTrue);
    expect(key.currentState!.handleBack(), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
