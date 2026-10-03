import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

const _screenshotNames = {
  'raiju-home-light',
  'raiju-home-dark',
  'raiju-chat-light',
  'raiju-chat-dark',
  'ompd-home-light',
  'ompd-home-dark',
  'ompd-relay-settings',
  'ompd-instance-list',
  'ompd-streaming-chat',
  'ompd-restored-chat-light',
  'ompd-restored-chat-dark',
  'ompd-live-model-reply',
  'ompd-live-saved-home',
  'ompd-live-restored-light',
  'ompd-live-restored-dark',
  'raiju-folded-home',
  'raiju-plus-menu',
  'raiju-collab-logo',
  'raiju-settings-connection',
  'raiju-settings-interface',
  'raiju-theme-menu',
  'raiju-local-search',
  'spark-folded-launch',
  'spark-expanded-light',
  'spark-minimized-light',
  'spark-expanded-dark',
  'spark-restored-bound-chat',
  'spark-live-transcript',
  'spark-chat-quick-controls',
  'spark-delete-confirmation',
};

const _pngSignature = <int>[137, 80, 78, 71, 13, 10, 26, 10];

Future<void> main() => integrationDriver(onScreenshot: _saveScreenshot);

Future<bool> _saveScreenshot(
  String name,
  List<int> bytes, [
  Map<String, Object?>? args,
]) async {
  if (!_screenshotNames.contains(name)) {
    throw ArgumentError.value(name, 'name', 'Unexpected screenshot name');
  }
  if (bytes.length < _pngSignature.length) {
    throw StateError('Screenshot $name is not a PNG');
  }
  for (var index = 0; index < _pngSignature.length; index++) {
    if (bytes[index] != _pngSignature[index]) {
      throw StateError('Screenshot $name is not a PNG');
    }
  }

  final directory = Directory('.work/screenshots');
  await directory.create(recursive: true);
  await File('${directory.path}/$name.png').writeAsBytes(bytes, flush: true);
  return true;
}
