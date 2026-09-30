// MODIFIED FOR RAIJU: Buzz authentication is retained as a neutral provider
// shape for original GUI modules. It never loads, generates, or stores keys.
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../community/community.dart';
import '../relay/backend_disabled.dart';

enum AuthStatus { unknown, unauthenticated, authenticated }

class AuthState {
  final AuthStatus status;
  final Community? community;

  const AuthState({required this.status, this.community});
}

class AuthNotifier extends AsyncNotifier<AuthState> {
  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.unauthenticated);

  Future<void> authenticateWithCommunity(Community community) =>
      Future.error(buzzBackendUnavailable);

  Future<void> signOut() => Future.error(buzzBackendUnavailable);
}

final authProvider = AsyncNotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);
