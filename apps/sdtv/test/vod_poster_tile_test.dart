import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_core/sdtv_core.dart';
import 'package:sdtv/theme.dart';
import 'package:sdtv/ui/widgets/vod_poster_tile.dart';
import 'package:sdtv/ui/widgets/vod_title_pane.dart';

void main() {
  testWidgets('watched poster shows a check overlay', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: sdtvDarkTheme,
        home: Scaffold(
          body: SizedBox(
            width: 160,
            height: 280,
            child: VodPosterTile(
              title: 'Harbor Nights',
              selected: false,
              focused: false,
              watched: true,
              onTap: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    final scrim = tester.widget<WatchedArtScrim>(find.byType(WatchedArtScrim));
    expect(scrim.lifted, isFalse);
    final veil = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byType(WatchedArtScrim),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(veil.color.a, closeTo(WatchedArtScrim.idleAlpha, 0.001));
  });

  testWidgets('focused watched poster lifts the dim and keeps the check', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: sdtvDarkTheme,
        home: Scaffold(
          body: SizedBox(
            width: 160,
            height: 280,
            child: VodPosterTile(
              title: 'Harbor Nights',
              selected: true,
              focused: true,
              watched: true,
              onTap: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    final scrim = tester.widget<WatchedArtScrim>(find.byType(WatchedArtScrim));
    expect(scrim.lifted, isTrue);
    final veil = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byType(WatchedArtScrim),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(veil.color.a, closeTo(WatchedArtScrim.liftedAlpha, 0.001));
  });

  testWidgets('unwatched poster has no check overlay', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: sdtvDarkTheme,
        home: Scaffold(
          body: SizedBox(
            width: 160,
            height: 280,
            child: VodPosterTile(
              title: 'Harbor Nights',
              selected: false,
              focused: false,
              onTap: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.check_rounded), findsNothing);
    expect(find.byType(WatchedArtScrim), findsNothing);
  });

  testWidgets('favorited poster shows a star overlay', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: sdtvDarkTheme,
        home: Scaffold(
          body: SizedBox(
            width: 160,
            height: 280,
            child: VodPosterTile(
              title: 'Harbor Nights',
              selected: false,
              focused: false,
              favorited: true,
              onTap: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    expect(find.byType(WatchedArtScrim), findsNothing);
  });

  testWidgets('title landing dims a finished poster', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: sdtvDarkTheme,
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 600,
            child: VodTitlePane(
              item: const VodItem(
                streamId: 9002,
                name: 'Another Title',
                categoryId: '10',
              ),
              info: const VodInfo(title: 'Another Title', plot: 'Finished.'),
              actions: const [
                (id: 'play', label: 'Play Now', icon: Icons.play_arrow),
              ],
              actionIndex: 0,
              watched: true,
              onAction: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    final scrim = tester.widget<WatchedArtScrim>(find.byType(WatchedArtScrim));
    expect(scrim.lifted, isFalse);
  });
}
