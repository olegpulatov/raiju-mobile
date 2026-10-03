import 'dart:convert';

import 'package:raiju_mobile/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'fresh appearance is Material and green without writing saved choices',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final storage = CommunityThemeStorage(prefs);
      final preference = storage.legacyPreference();
      expect(preference, defaultCommunityTheme);
      expect(preference.theme, 'material-theme-lighter');
      expect(preference.accent, '#22c55e');
      expect(preference.mode, ThemeMode.system);
      expect(prefs.getKeys(), isEmpty);
      final schemes = resolveSchemes(preference.theme, preference.mode);
      expect(schemes.lightTheme?.name, 'material-theme-lighter');
      expect(schemes.darkTheme?.name, 'material-theme');
      expect(schemes.forcedMode, isNull);
    },
  );

  test(
    'saved complete appearance survives default changes and reload',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      const explicit = CommunityThemePreference(
        theme: 'buzz-dark',
        accent: 'neutral',
        followSystem: false,
      );
      await CommunityThemeStorage(prefs).writeLegacy(explicit);
      final savedValues = prefs
          .getKeys()
          .map((key) => (key, prefs.get(key)))
          .toList();
      expect(CommunityThemeStorage(prefs).legacyPreference(), explicit);
      expect(
        prefs.getKeys().map((key) => (key, prefs.get(key))).toList(),
        savedValues,
      );
    },
  );

  test('explicit legacy theme mode and accent stay unchanged', () async {
    SharedPreferences.setMockInitialValues({
      'buzz_theme_mode': 'light',
      'buzz_color_scheme': 'github-light',
      'buzz_accent_color': 0,
    });
    final prefs = await SharedPreferences.getInstance();
    final preference = CommunityThemeStorage(prefs).legacyPreference();
    expect(preference.theme, 'github-light');
    expect(preference.accent, '#3b82f6');
    expect(preference.mode, ThemeMode.light);
    expect(prefs.getString('buzz_color_scheme'), 'github-light');
    expect(prefs.getInt('buzz_accent_color'), 0);
  });

  test('desktop v1 payload round-trips exactly', () {
    final preference = CommunityThemePreference.fromJson({
      'version': 1,
      'theme': 'github-dark',
      'accent': '#c0a2f1',
      'followSystem': false,
    });

    expect(preference.mode, ThemeMode.dark);
    expect(
      jsonEncode(preference.toJson()),
      '{"version":1,"theme":"github-dark","accent":"#c0a2f1","followSystem":false}',
    );
  });

  test('rejects unknown themes, accents, and future versions', () {
    for (final payload in [
      {
        'version': 2,
        'theme': 'buzz',
        'accent': '#3b82f6',
        'followSystem': true,
      },
      {
        'version': 1,
        'theme': 'unknown',
        'accent': '#3b82f6',
        'followSystem': true,
      },
      {
        'version': 1,
        'theme': 'buzz',
        'accent': '#000000',
        'followSystem': true,
      },
    ]) {
      expect(
        () => CommunityThemePreference.fromJson(payload),
        throwsFormatException,
      );
    }
  });

  test('storage is scoped by pubkey and normalized relay URL', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = CommunityThemeStorage(prefs);
    const a = CommunityThemePreference(
      theme: 'buzz',
      accent: '#3b82f6',
      followSystem: true,
    );
    const b = CommunityThemePreference(
      theme: 'dracula',
      accent: '#ef4444',
      followSystem: false,
    );

    await storage.write('pk', 'WSS://Relay.Example///', a);
    await storage.write('pk', 'wss://other.example', b);

    expect(storage.read('pk', 'wss://relay.example'), a);
    expect(storage.read('pk', 'wss://other.example/'), b);
    expect(storage.read('other-pk', 'wss://relay.example'), isNull);
  });

  test('dirty outbox survives restart and clears only exact ack', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = CommunityThemeStorage(prefs);
    const pending = CommunityThemePreference(
      theme: 'dracula',
      accent: '#ef4444',
      followSystem: false,
    );
    const newer = CommunityThemePreference(
      theme: 'houston',
      accent: '#a855f7',
      followSystem: false,
    );

    await storage.writeOutbox('pk', 'wss://relay.example', pending);
    expect(
      CommunityThemeStorage(prefs).readOutbox('pk', 'wss://relay.example'),
      pending,
    );
    await storage.writeOutbox('pk', 'wss://relay.example', newer);
    await storage.clearOutbox('pk', 'wss://relay.example', pending);
    expect(storage.readOutbox('pk', 'wss://relay.example'), newer);
    await storage.clearOutbox('pk', 'wss://relay.example', newer);
    expect(storage.readOutbox('pk', 'wss://relay.example'), isNull);
  });

  test('legacy accent indexes migrate without inventing wire values', () async {
    SharedPreferences.setMockInitialValues({
      'buzz_theme_mode': 'dark',
      'buzz_color_scheme': 'dracula',
      'buzz_accent_color': 8,
    });
    final prefs = await SharedPreferences.getInstance();
    final preference = CommunityThemeStorage(prefs).legacyPreference();

    expect(
      preference,
      const CommunityThemePreference(
        theme: 'dracula',
        accent: 'neutral',
        followSystem: false,
      ),
    );
    expect(preference.mode, ThemeMode.dark);
    expect(legacyAccentWireValue(6), '#a855f7');
    expect(legacyAccentWireValue(7), '#6366f1');
  });
}
