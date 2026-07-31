import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/auth_repository.dart';

class AuthState {
  const AuthState({
    required this.isAuthenticated,
    required this.isLoading,
    this.errorMessage,
  });

  static const initial = AuthState(isAuthenticated: false, isLoading: true);

  final bool isAuthenticated;
  final bool isLoading;
  final String? errorMessage;

  AuthState copyWith({bool? isAuthenticated, bool? isLoading, String? errorMessage}) =>
      AuthState(
        isAuthenticated: isAuthenticated ?? this.isAuthenticated,
        isLoading: isLoading ?? this.isLoading,
        errorMessage: errorMessage,
      );
}

/// Fuente de verdad de la sesión: la lee el router (`app_router.dart`) para decidir si
/// redirige a `/login`, y la actualiza tanto el login/logout explícito del usuario como el
/// interceptor 401 de `ApiClient` (ver `core/providers.dart`).
class AuthController extends StateNotifier<AuthState> {
  AuthController(this._authRepository) : super(AuthState.initial) {
    _checkExistingSession();
  }

  final AuthRepository _authRepository;

  Future<void> _checkExistingSession() async {
    final isAuthenticated = await _authRepository.isAuthenticated();
    state = state.copyWith(isAuthenticated: isAuthenticated, isLoading: false);
  }

  Future<void> login({required String email, required String password}) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      await _authRepository.login(email: email, password: password);
      state = state.copyWith(isAuthenticated: true, isLoading: false);
    } on Object {
      state = state.copyWith(
        isAuthenticated: false,
        isLoading: false,
        errorMessage: 'Email o contraseña incorrectos.',
      );
    }
  }

  Future<void> register({required String email, required String password}) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      await _authRepository.register(email: email, password: password);
      await login(email: email, password: password);
    } on Object {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'No se pudo registrar (¿el email ya existe?).',
      );
    }
  }

  Future<void> logout() async {
    await _authRepository.logout();
    state = state.copyWith(isAuthenticated: false);
  }
}
