import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv/theme.dart';
import 'package:sdtv/ui/widgets/vod_title_pane.dart';
import 'package:sdtv_core/sdtv_core.dart';

const _item = VodItem(streamId: 9001, name: 'Demo Feature', categoryId: '10');

Widget _pane(List<({String id, String label, IconData icon})> actions) {
  return MaterialApp(
    theme: sdtvDarkTheme,
    home: Scaffold(
      body: SizedBox(
        width: 1030,
        height: 690,
        child: VodTitlePane(
          item: _item,
          info: const VodInfo(title: 'Demo Feature', plot: 'Plot.'),
          actions: actions,
          actionIndex: 0,
          onAction: (_) {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('poster keeps its size when the info load adds buttons', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _pane(const [
        (id: 'play', label: 'Play Now', icon: Icons.play_arrow),
        (id: 'favorite', label: 'Add to Favorites', icon: Icons.star_outline),
      ]),
    );
    final before = tester.getSize(find.byType(AspectRatio).first);

    await tester.pumpWidget(
      _pane(const [
        (id: 'resume', label: 'Resume', icon: Icons.play_arrow),
        (id: 'start', label: 'Start from beginning', icon: Icons.replay),
        (id: 'favorite', label: 'Add to Favorites', icon: Icons.star_outline),
        (id: 'seasons', label: 'Seasons & episodes', icon: Icons.list),
        (id: 'trailer', label: 'Watch trailer', icon: Icons.movie),
      ]),
    );
    final after = tester.getSize(find.byType(AspectRatio).first);

    expect(after, before);
    expect(before.height, greaterThan(400)); // uses the pane's height
  });
}
