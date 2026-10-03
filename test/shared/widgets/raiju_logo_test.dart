import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:raiju_mobile/shared/theme/theme.dart';
import 'package:raiju_mobile/shared/widgets/raiju_logo.dart';
import 'package:raiju_mobile/shared/widgets/tappable_flapping_bee.dart';

Widget _testable({
  required Widget child,
  bool dark = false,
  bool disableAnimations = false,
}) {
  return ProviderScope(
    child: MaterialApp(
      theme: dark ? AppTheme.dark() : AppTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(body: Center(child: child)),
      ),
    ),
  );
}

void main() {
  for (final dark in [false, true]) {
    testWidgets('mark follows ${dark ? 'dark' : 'light'} theme primary', (
      tester,
    ) async {
      await tester.pumpWidget(
        _testable(dark: dark, child: const RaijuLogo(width: 76)),
      );
      final logoContext = tester.element(find.byType(RaijuLogo));
      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as AssetImage).assetName, RaijuLogo.asset);
      expect(image.color, Theme.of(logoContext).colorScheme.primary);
      expect(image.colorBlendMode, BlendMode.srcIn);
      expect(tester.getSize(find.byType(RaijuLogo)), const Size.square(76));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('explicit mark color overrides theme without changing artwork', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testable(child: const RaijuLogo(color: Colors.orange)),
    );
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.color, Colors.orange);
    expect((image.image as AssetImage).assetName, RaijuLogo.asset);
  });

  testWidgets('tap animates Raiju and keeps brand semantics', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _testable(
        child: const TappableFlappingBee(width: 76, color: Colors.green),
      ),
    );
    expect(find.bySemanticsLabel('Raiju mark'), findsOneWidget);
    expect(find.bySemanticsLabel('Buzz bee'), findsNothing);
    expect(tester.widget<RaijuLogo>(find.byType(RaijuLogo)).motion, 0);
    await tester.tap(find.byType(TappableFlappingBee));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      tester.widget<RaijuLogo>(find.byType(RaijuLogo)).motion,
      greaterThan(0),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<RaijuLogo>(find.byType(RaijuLogo)).motion, 0);
    semantics.dispose();
  });

  testWidgets('reduced motion keeps tapped Raiju static', (tester) async {
    await tester.pumpWidget(
      _testable(
        disableAnimations: true,
        child: const TappableFlappingBee(width: 76, color: Colors.green),
      ),
    );
    await tester.tap(find.byType(TappableFlappingBee));
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.widget<RaijuLogo>(find.byType(RaijuLogo)).motion, 0);
  });
}
