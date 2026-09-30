// MODIFIED FOR RAIJU: Buzz account/Nostr pairing is inactive; this provider
// now joins encrypted OMP collaboration sessions through CompanionController.
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../companion_controller.dart';
import '../../harness/harness.dart';
import '../../raiju/companion_provider.dart';
import '../../shared/auth/auth.dart' show Community;
import 'pairing_socket.dart';

enum PairingStatus {
  idle,
  connecting,
  confirmingSas,
  transferring,
  storing,
  success,
  error,
}

class PairingState {
  final PairingStatus status;
  final String? errorMessage;
  final String? sasCode;
  final bool userConfirmedSas;
  final bool sendsIdentityToDesktop;
  final bool protectSensitiveActions;
  final bool authorizationInProgress;

  /// The durable local chat created by the most recent successful join.
  final String? joinedChatId;
  final ChatThread? joinedChat;

  const PairingState({
    this.status = PairingStatus.idle,
    this.errorMessage,
    this.sasCode,
    this.userConfirmedSas = false,
    this.sendsIdentityToDesktop = false,
    this.protectSensitiveActions = true,
    this.authorizationInProgress = false,
    this.joinedChatId,
    this.joinedChat,
  });

  PairingState copyWith({
    PairingStatus? status,
    String? errorMessage,
    String? sasCode,
    bool? userConfirmedSas,
    bool? sendsIdentityToDesktop,
    bool? protectSensitiveActions,
    bool? authorizationInProgress,
    String? joinedChatId,
    ChatThread? joinedChat,
    bool clearErrorMessage = false,
    bool clearJoinedChat = false,
  }) => PairingState(
    status: status ?? this.status,
    errorMessage: clearErrorMessage ? null : errorMessage ?? this.errorMessage,
    sasCode: sasCode ?? this.sasCode,
    userConfirmedSas: userConfirmedSas ?? this.userConfirmedSas,
    sendsIdentityToDesktop:
        sendsIdentityToDesktop ?? this.sendsIdentityToDesktop,
    protectSensitiveActions:
        protectSensitiveActions ?? this.protectSensitiveActions,
    authorizationInProgress:
        authorizationInProgress ?? this.authorizationInProgress,
    joinedChatId: clearJoinedChat ? null : joinedChatId ?? this.joinedChatId,
    joinedChat: clearJoinedChat ? null : joinedChat ?? this.joinedChat,
  );
}

// Kept only so downstream widgets/tests that constructed the old notifier keep
// compiling. Neither hook is invoked by the Raiju flow.
typedef PairingSocketFactory =
    PairingSocket Function({
      required String wsUrl,
      required String ephemeralPrivkey,
      required void Function(List<dynamic> message) onMessage,
      required void Function(Object? error) onDisconnected,
    });
typedef PairingCredentialValidator =
    Future<void> Function({required String relayUrl, required String? nsec});

const identityExportAuthorizationTtl = Duration(minutes: 2);
final identityExportClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

class PairingNotifier extends Notifier<PairingState> {
  PairingNotifier({
    PairingSocketFactory? socketFactory,
    PairingCredentialValidator? credentialValidator,
  });
  int _generation = 0;

  @override
  PairingState build() {
    ref.onDispose(() => _generation++);
    return const PairingState();
  }

  /// QR scans and pasted links intentionally take this exact same path.
  Future<void> pair(String rawInput) async {
    if (state.status == PairingStatus.connecting) return;
    final generation = ++_generation;

    state = const PairingState(status: PairingStatus.connecting);
    try {
      final chat = await ref.read(companionControllerProvider).join(rawInput);
      if (generation != _generation) {
        await ref.read(companionControllerProvider).remove(chat.id);
        return;
      }
      state = PairingState(
        status: PairingStatus.success,
        joinedChatId: chat.id,
        joinedChat: chat,
      );
    } on HarnessException catch (error) {
      if (generation != _generation) return;
      state = PairingState(
        status: PairingStatus.error,
        errorMessage: error.message,
      );
    } catch (_) {
      if (generation != _generation) return;
      state = const PairingState(
        status: PairingStatus.error,
        errorMessage: 'Could not connect to this OMP session. Check the link and try again.',
      );
    }
  }

  void reset() {
    _generation++;
    state = const PairingState();
  }

  /// Buzz identity export is deliberately unavailable in Raiju.
  Future<bool> authorizeIdentityExport({required Community community}) async {
    state = state.copyWith(
      errorMessage: 'Buzz identity transfer is unavailable in Raiju.',
    );
    return false;
  }

  void confirmSas() {}
  void denySas() => reset();
  void setProtectSensitiveActions(bool value) {}
}

final pairingProvider = NotifierProvider<PairingNotifier, PairingState>(
  PairingNotifier.new,
);
