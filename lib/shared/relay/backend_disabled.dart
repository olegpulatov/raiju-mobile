// MODIFIED FOR RAIJU: Buzz/Nostr backend transport is retained only as inactive
// compatibility debt. The OMP harness is the sole chat network boundary.

/// Stable fail-closed error for every retained Buzz backend operation.
class BuzzBackendUnavailableException implements Exception {
  const BuzzBackendUnavailableException([
    this.message =
        'Buzz account, relay, media, and push services are unavailable in Raiju.',
  ]);

  final String message;

  @override
  String toString() => message;
}

const buzzBackendUnavailable = BuzzBackendUnavailableException();
