import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raiju_mobile/shared/theme/theme.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('default accent', () {
    test(
      'absent local preference is green and explicit saved indexes stay',
      () async {
        for (final saved in <int?>[null, neutralAccentIndex, 1, 3, 8]) {
          SharedPreferences.setMockInitialValues({'buzz_accent_color': ?saved});
          final prefs = await SharedPreferences.getInstance();
          final container = ProviderContainer(
            overrides: [savedPrefsProvider.overrideWithValue(prefs)],
          );
          try {
            expect(
              container.read(accentProvider),
              saved ?? defaultLocalAccentIndex,
            );
            expect(prefs.getInt('buzz_accent_color'), saved);
          } finally {
            container.dispose();
          }
        }
      },
    );

    test('legacy invalid wire fallback is unchanged', () {
      expect(legacyAccentWireValue(null), '#3b82f6');
      expect(legacyAccentWireValue(-1), '#3b82f6');
      expect(legacyAccentWireValue(99), '#3b82f6');
    });

    test('uses green on the default light Material scheme', () {
      final resolved = resolveSchemes(null, ThemeMode.light);

      final accented = applyAccent(resolved.light, defaultLocalAccentIndex);

      expect(resolved.lightTheme?.name, 'material-theme-lighter');
      expect(accented.primary, const Color(0xFF22C55E));
    });

    test('uses green on dark schemes', () {
      final resolved = resolveSchemes('github-dark', ThemeMode.dark);
      final base = resolved.dark;

      final accented = applyAccent(base, defaultLocalAccentIndex);

      expect(resolved.forcedMode, ThemeMode.dark);
      expect(accented.primary, const Color(0xFF4ADE80));
      expect(
        _contrastRatio(accented.primary, accented.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(accented.onPrimary, contrastForeground(accented.primary));
    });

    test('explicit neutral accent keeps its dark foreground rendering', () {
      final resolved = resolveSchemes('github-dark', ThemeMode.dark);
      final accented = applyAccent(resolved.dark, neutralAccentIndex);
      expect(accented.primary, resolved.dark.onSurface);
    });
  });
}

double _contrastRatio(Color a, Color b) {
  final aLum = a.computeLuminance();
  final bLum = b.computeLuminance();
  final lightest = aLum > bLum ? aLum : bLum;
  final darkest = aLum > bLum ? bLum : aLum;
  return (lightest + 0.05) / (darkest + 0.05);
}
