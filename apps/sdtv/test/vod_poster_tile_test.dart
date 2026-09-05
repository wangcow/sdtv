import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv/theme.dart';
import 'package:sdtv/ui/widgets/vod_poster_tile.dart';

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
  });
}
