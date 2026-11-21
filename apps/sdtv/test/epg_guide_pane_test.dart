import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv/ui/widgets/epg_guide_pane.dart';
import 'package:sdtv_core/sdtv_core.dart';

void main() {
  testWidgets('focused channel with an empty guide builds (no error row)', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime(2026, 11, 20, 22, 10);
    const channels = [
      LiveChannel(streamId: 1, name: 'Hallmark', categoryId: 'x', num: 565),
      LiveChannel(streamId: 2, name: 'Elf', categoryId: 'x', num: 5483),
      LiveChannel(streamId: 3, name: 'Yule', categoryId: 'x', num: 123456),
    ];
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EpgGuidePane(
            channels: channels,
            channelIndex: 1, // Elf: the panel returned an empty guide
            categoryTitle: 'CHRISTMAS',
            windowStart: DateTime(2026, 11, 20, 22),
            focusTime: now,
            now: now,
            epgFor: (ch) => ShortEpg(streamId: ch.streamId, listings: const []),
            scrollController: controller,
            onTapChannel: (_) {},
            onTapProgram: (_, _) {},
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Elf'), findsOneWidget);

    // Channel numbers stay on one line: 4 digits at full size, longer
    // ones scaled down to the same column.
    for (final n in ['565', '5483', '123456']) {
      final r = tester.getRect(find.text(n)); // on screen, after scaling
      expect(r.height, lessThan(30), reason: '$n wrapped');
      expect(r.width, lessThanOrEqualTo(46.01), reason: '$n overflows');
    }
  });
}
