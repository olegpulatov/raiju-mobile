import 'package:buzz/spark/widgets/spark_level_visualizer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'silent meter stays zero and low input/output have bounded visual response',
    () {
      expect(sparkVisualResponse(0, 0), 0);
      final low = sparkVisualResponse(.01, 0);
      expect(low, greaterThan(.01));
      expect(low, lessThan(1));
      expect(sparkVisualResponse(0, .01), low);
      expect(sparkVisualResponse(100, 0), 1);
      expect(sparkVisualResponse(1, 0), 1);
      expect(sparkVisualResponse(double.nan, 0), 0);
      expect(sparkVisualResponse(-.02, double.infinity), 0);
    },
  );

  testWidgets(
    'silent levels do not animate and accessibility describes silence',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(_fixture(reduceMotion: false));
        expect(
          find.bySemanticsLabel('Spark voice connected, no audio level'),
          findsOneWidget,
        );
        final quiet = _painter(tester);
        await tester.pump(const Duration(milliseconds: 300));
        expect(_painter(tester).shouldRepaint(quiet), isFalse);

        await tester.pumpWidget(
          _fixture(input: double.nan, reduceMotion: false),
        );
        expect(tester.takeException(), isNull);
        expect(
          find.bySemanticsLabel('Spark voice connected, no audio level'),
          findsOneWidget,
        );
        await tester.pumpWidget(_fixture(input: .01, reduceMotion: false));
        expect(
          find.bySemanticsLabel('Spark voice audio level'),
          findsOneWidget,
        );
        await tester.pumpWidget(_fixture(input: 100, active: false));
        expect(find.bySemanticsLabel('Spark is idle'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('real levels animate unless reduced motion is requested', (
    tester,
  ) async {
    await tester.pumpWidget(_fixture(input: .05, reduceMotion: false));
    final active = _painter(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(_painter(tester).shouldRepaint(active), isTrue);

    await tester.pumpWidget(_fixture(input: .05));
    final reduced = _painter(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_painter(tester).shouldRepaint(reduced), isFalse);

    await tester.pumpWidget(_fixture(reduceMotion: false));
    final silence = _painter(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(_painter(tester).shouldRepaint(silence), isFalse);
    await tester.pumpWidget(_fixture(input: .01, width: 16));
    expect(tester.getSize(find.byType(SparkLevelVisualizer)).width, 16);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'repeated equal samples refresh activity and old output expires',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _fixture(output: .02, levelRevision: 1, reduceMotion: false),
        );
        expect(
          find.bySemanticsLabel('Spark voice audio level'),
          findsOneWidget,
        );
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpWidget(
          _fixture(output: .02, levelRevision: 2, reduceMotion: false),
        );
        await tester.pump(const Duration(milliseconds: 350));
        expect(
          find.bySemanticsLabel('Spark voice audio level'),
          findsOneWidget,
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump();
        expect(
          find.bySemanticsLabel('Spark voice connected, no audio level'),
          findsOneWidget,
        );
        final expired = _painter(tester);
        await tester.pump(const Duration(milliseconds: 300));
        expect(_painter(tester).shouldRepaint(expired), isFalse);
        await tester.pumpWidget(
          _fixture(output: .02, levelRevision: 3, reduceMotion: false),
        );
        expect(
          find.bySemanticsLabel('Spark voice audio level'),
          findsOneWidget,
        );
        await tester.pumpWidget(_fixture(levelRevision: 4));
        expect(
          find.bySemanticsLabel('Spark voice connected, no audio level'),
          findsOneWidget,
        );
      } finally {
        semantics.dispose();
      }
    },
  );
}

Widget _fixture({
  double input = 0,
  double output = 0,
  bool active = true,
  bool reduceMotion = true,
  double width = 190,
  int levelRevision = 0,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          height: 28,
          child: SparkLevelVisualizer(
            inputLevel: input,
            outputLevel: output,
            levelRevision: levelRevision,
            active: active,
          ),
        ),
      ),
    ),
  ),
);

CustomPainter _painter(WidgetTester tester) => tester
    .widget<CustomPaint>(
      find.descendant(
        of: find.byType(SparkLevelVisualizer),
        matching: find.byType(CustomPaint),
      ),
    )
    .painter!;
