// Modified for Raiju: retain Buzz app, remove account/push/age startup gates.
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'raiju/acceptance_probe.dart';
import 'shared/theme/theme_provider.dart';

void main() => runBuzzApp(const App());

Future<void> runBuzzApp(Widget app) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Pre-load preferences so the first frame uses the saved theme/accent.
  final prefs = await SharedPreferences.getInstance();

  final acceptance = RaijuAcceptanceProbeConfiguration.fromEnvironment();
  final child = acceptance == null
      ? app
      : RaijuAcceptanceProbe(configuration: acceptance, child: app);
  runApp(
    ProviderScope(
      overrides: [
        savedPrefsProvider.overrideWithValue(prefs),
      ],
      child: child,
    ),
  );
}
