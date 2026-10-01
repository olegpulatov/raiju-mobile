import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool _registered = false;

/// Register collectors without reading assets during application startup.
void registerRaijuLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    const localLicenses = <String, List<String>>{
      'licenses/NOTICE': ['Raiju mobile attributions'],
      'licenses/buzz-apache-2.0.txt': ['Buzz mobile'],
      'licenses/emoji-mart-mit.txt': ['@emoji-mart/data 1.2.1'],
      'licenses/omp-mit.txt': ['OMP / Iskra'],
      'spark-core/LICENSE': ['Spark core 0.1.0'],
      'assets/fonts/Geist-LICENSE.txt': ['Geist / Geist Mono fonts'],
      'assets/fonts/Inter-LICENSE.txt': ['Inter fonts'],
      'licenses/google-ml-kit-terms.txt': ['Google ML Kit SDK terms'],
    };
    for (final entry in localLicenses.entries) {
      yield LicenseEntryWithLineBreaks(
        entry.value,
        await rootBundle.loadString(entry.key),
      );
    }
    final notices = jsonDecode(
      await rootBundle.loadString('licenses/native-notices.json'),
    ) as Map<String, dynamic>;
    for (final entry in notices['entries'] as List<dynamic>) {
      final notice = entry as Map<String, dynamic>;
      yield LicenseEntryWithLineBreaks(
        (notice['packages'] as List<dynamic>).cast<String>(),
        notice['text'] as String,
      );
    }
  });
}
