// Modified for Raiju: appearance is local-only; no Nostr identity or sync.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'accent_colors.dart';
import 'community_theme_preference.dart';
import 'theme_provider.dart';

class CommunityThemeNotifier extends Notifier<CommunityThemePreference> {
  late CommunityThemeStorage _storage;
  Future<void> _persistenceQueue = Future<void>.value();

  @override
  CommunityThemePreference build() {
    _storage = ref.watch(communityThemeStorageProvider);
    return _storage.legacyPreference();
  }

  void setMode(ThemeMode mode) {
    var theme = state.theme;
    if (mode == ThemeMode.system) {
      theme = schemeForAppearanceMode(theme, mode) ?? theme;
    } else {
      final effective = effectiveTheme(theme, mode);
      if (effective != null) theme = effective.name;
    }
    _save(
      CommunityThemePreference(
        theme: theme,
        accent: state.accent,
        followSystem: mode == ThemeMode.system,
      ),
    );
  }

  void setTheme(String? theme) {
    _save(
      CommunityThemePreference(
        theme: theme ?? defaultSchemeName,
        accent: state.accent,
        followSystem: state.followSystem,
      ),
    );
  }

  void setAccent(int index) {
    if (index < 0 || index >= accentColors.length) return;
    _save(
      CommunityThemePreference(
        theme: state.theme,
        accent: accentColors[index].wireValue,
        followSystem: state.followSystem,
      ),
    );
  }

  /// Persists a complete theme-picker selection as one durable snapshot.
  void setPreference(CommunityThemePreference preference) {
    _save(preference);
  }

  void _save(CommunityThemePreference preference) {
    if (preference == state) return;
    state = preference;
    unawaited(_enqueuePersistence(() async {
      await _storage.writeLegacy(preference);
    }));
  }

  Future<void> _enqueuePersistence(Future<void> Function() operation) {
    final result = _persistenceQueue.then((_) => operation());
    _persistenceQueue = result.catchError((Object _) {});
    return result;
  }

  Future<void> flush() => _persistenceQueue;

}


final communityThemeStorageProvider = Provider<CommunityThemeStorage>(
  (ref) => CommunityThemeStorage(ref.watch(savedPrefsProvider)),
);

final communityThemeProvider =
    NotifierProvider<CommunityThemeNotifier, CommunityThemePreference>(
      CommunityThemeNotifier.new,
    );
