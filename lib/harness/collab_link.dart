// OMP collab protocol v3 link/envelope behavior, translated for Raiju from
// @oh-my-pi/collab-web/src/lib/link.ts (vendored mirror in OMP).
import 'dart:convert';
import 'dart:typed_data';

const int collabProtocolVersion = 3;
const String defaultCollabRelay = 'wss://ompc.home.arpa';
const int collabEnvelopeHeaderLength = 4;
const int collabRoomKeyBytes = 32;
const int collabWriteTokenBytes = 16;

final RegExp _roomPath = RegExp(
  r'^/r/([A-Za-z0-9_-]{10,64})(?:\.([A-Za-z0-9_-]+))?$',
);
final RegExp _bareLink = RegExp(
  r'^([A-Za-z0-9_-]{10,64})[#.]([A-Za-z0-9_-]+)$',
);
final RegExp _base64Url = RegExp(r'^[A-Za-z0-9_-]+$');
const Set<String> _localHosts = {'localhost', '127.0.0.1', '::1', '[::1]'};

final class CollabLinkException implements Exception {
  const CollabLinkException(this.message);
  final String message;
  @override
  String toString() => message;
}

final class ParsedCollabLink {
  const ParsedCollabLink({
    required this.socketUri,
    required this.roomId,
    required this.key,
    this.writeToken,
  });

  final Uri socketUri;
  final String roomId;
  final Uint8List key;
  final Uint8List? writeToken;

  /// Relay origin only. It deliberately excludes room and bearer material.
  String get safeEndpoint => '${socketUri.scheme}://${socketUri.authority}';

  @override
  String toString() => 'ParsedCollabLink($safeEndpoint, secret: redacted)';
}

String encodeBase64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List? decodeBase64Url(String text) {
  if (!_base64Url.hasMatch(text)) return null;
  final padded = text.padRight(text.length + ((4 - text.length % 4) % 4), '=');
  try {
    return Uint8List.fromList(base64Url.decode(padded));
  } on FormatException {
    return null;
  }
}

ParsedCollabLink parseCollabLink(
  String input, {
  String defaultRelay = defaultCollabRelay,
}) {
  var text = input.trim().replaceAll(RegExp('%23', caseSensitive: false), '#');
  final bare = _bareLink.firstMatch(text);
  if (bare != null) {
    text =
        '${validateCollabRelay(defaultRelay)}/r/${bare.group(1)}.${bare.group(2)}';
  } else if (!text.contains('://')) {
    text = 'wss://$text';
  }

  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw const CollabLinkException(
      'That is not a valid OMP collaboration link.',
    );
  }

  if ((uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.fragment.isNotEmpty) {
    try {
      return parseCollabLink(uri.fragment, defaultRelay: defaultRelay);
    } on CollabLinkException {
      // A malformed wrapper fragment falls through to direct-link validation.
    }
  }

  final origin = _normalizeRelay(uri);
  final match = _roomPath.firstMatch(uri.path);
  if (match == null) {
    if (uri.scheme != 'http' &&
        uri.scheme != 'https' &&
        uri.fragment.isNotEmpty) {
      return parseCollabLink(uri.fragment, defaultRelay: defaultRelay);
    }
    throw const CollabLinkException(
      'The collaboration link must contain a /r/<room> path.',
    );
  }

  final roomId = match.group(1)!;
  final secretText = match.group(2) ?? uri.fragment;
  if (secretText.isEmpty) {
    throw const CollabLinkException(
      'The collaboration link is missing its key.',
    );
  }
  final secret = decodeBase64Url(secretText);
  if (secret == null ||
      (secret.length != collabRoomKeyBytes &&
          secret.length != collabRoomKeyBytes + collabWriteTokenBytes)) {
    throw const CollabLinkException(
      'The collaboration key must be a valid view or full key.',
    );
  }

  return ParsedCollabLink(
    socketUri: origin.replace(path: '/r/$roomId', query: null, fragment: null),
    roomId: roomId,
    key: Uint8List.fromList(secret.take(collabRoomKeyBytes).toList()),
    writeToken: secret.length == collabRoomKeyBytes
        ? null
        : Uint8List.fromList(secret.skip(collabRoomKeyBytes).toList()),
  );
}

bool isBareCollabCode(String input) {
  final text = input.trim().replaceAll(
    RegExp('%23', caseSensitive: false),
    '#',
  );
  if (_bareLink.hasMatch(text)) return true;
  final uri = Uri.tryParse(text);
  return uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      _bareLink.hasMatch(uri.fragment);
}

/// A manual-code preference is an origin, never a path, credential, or token.
String validateCollabRelay(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.path.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.scheme != 'wss' && uri.scheme != 'ws')) {
    throw const CollabLinkException(
      'Enter a relay origin (wss://host, or ws://localhost).',
    );
  }
  return _normalizeRelay(uri).toString();
}

/// Resolve bare manual tokens, including browser wrappers with bare fragments.
/// Wrappers containing full relay links retain their embedded destination.
String pinBareCollabLink(
  String input, {
  String defaultRelay = defaultCollabRelay,
}) {
  if (!isBareCollabCode(input)) return input;
  final parsed = parseCollabLink(input, defaultRelay: defaultRelay);
  final secret = <int>[
    ...parsed.key,
    if (parsed.writeToken != null) ...parsed.writeToken!,
  ];
  return parsed.socketUri.replace(fragment: encodeBase64Url(secret)).toString();
}

Uri _normalizeRelay(Uri uri) {
  final scheme = switch (uri.scheme) {
    'wss' || 'https' => 'wss',
    'ws' || 'http' => 'ws',
    _ => throw const CollabLinkException(
      'The collaboration relay uses an unsupported URL scheme.',
    ),
  };
  if (scheme == 'ws' && !_localHosts.contains(uri.host.toLowerCase())) {
    throw const CollabLinkException(
      'Remote collaboration relays must use a secure connection.',
    );
  }
  return Uri(
    scheme: scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  );
}

Uint8List packCollabEnvelope(int peerId, List<int> sealed) {
  if (peerId < 0 || peerId > 0xffffffff) {
    throw RangeError.range(peerId, 0, 0xffffffff, 'peerId');
  }
  final result = Uint8List(collabEnvelopeHeaderLength + sealed.length);
  ByteData.sublistView(result).setUint32(0, peerId, Endian.big);
  result.setRange(collabEnvelopeHeaderLength, result.length, sealed);
  return result;
}

({int peerId, Uint8List payload})? unpackCollabEnvelope(List<int> bytes) {
  if (bytes.length < collabEnvelopeHeaderLength) return null;
  final copy = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  return (
    peerId: ByteData.sublistView(copy, 0, 4).getUint32(0, Endian.big),
    payload: Uint8List.sublistView(copy, collabEnvelopeHeaderLength),
  );
}
