import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/app/bottom_bar_layout.dart';

void main() {
  testWidgets(
    'overlay paints rows under the bar and scrolls the last row clear',
    (tester) async {
      var overlay = true;
      var playerHeight = 0.0;
      late StateSetter update;
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 390,
              height: 500,
              child: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return BottomBarLayout(
                    overlay: overlay,
                    body: Builder(
                      builder: (context) => ListView.builder(
                        key: const ValueKey('rows'),
                        controller: controller,
                        padding: EdgeInsets.only(
                          bottom: BottomBarInset.of(context),
                        ),
                        itemCount: 20,
                        itemExtent: 60,
                        itemBuilder: (_, index) =>
                            Text('Row $index', key: ValueKey(index)),
                      ),
                    ),
                    footer: SizedBox(
                      key: const ValueKey('footer'),
                      height: 84 + playerHeight,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final rows = find.byKey(const ValueKey('rows'));
      final footer = find.byKey(const ValueKey('footer'));
      final element = tester.element(rows);
      expect(tester.getRect(rows).bottom, tester.getRect(footer).bottom);
      expect(
        tester
            .getRect(find.byKey(const ValueKey(7)))
            .overlaps(tester.getRect(footer)),
        isTrue,
      );
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      expect(
        tester.getRect(find.byKey(const ValueKey(19))).bottom,
        tester.getRect(footer).top,
      );

      // The measured inset follows the player as well as the safe-area bar.
      update(() => playerHeight = 70);
      await tester.pump();
      await tester.pump();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      expect(
        tester.getRect(find.byKey(const ValueKey(19))).bottom,
        tester.getRect(footer).top,
      );

      update(() => overlay = false);
      await tester.pump();
      expect(identical(tester.element(rows), element), isTrue);
      expect(tester.getRect(rows).bottom, tester.getRect(footer).top);
      expect(tester.takeException(), isNull);
    },
  );
}
