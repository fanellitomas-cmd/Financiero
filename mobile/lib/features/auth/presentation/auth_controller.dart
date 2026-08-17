import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../data/auth_repository.dart';

@immutable
class AuthState {
  const AuthState({
    required this.isAuthenticated,
    required this.isLoading,
    this.errorMessage,
  });

  /// `isLoading: true` de arranque porque todavía no se sabe si hay token guardado. Sin esto, el
  /// router redirigiría a `/auth` en el primer frame y la sesión guardada parpadearía como ausente.
  static const initial = AuthState(isAuthenticated: false, isLoading: true);

  final bool isAuthenticated;
  final bool isLoading;
  final String? errorMessage;

  /// `errorMessage` NO se propaga si no se lo pasa: cada intento arranca sin el error del anterior.
  /// Con la semántica opuesta, un mensaje de "contraseña incorrecta" sobreviviría al login exitoso.
  AuthState copyWith({
    bool? isAuthenticated,
    bool? isLoading,
    String? errorMessage,
  }) =>
      AuthState(
        isAuthenticated: isAuthenticated ?? this.isAuthenticated,
        isLoading: isLoading ?? this.isLoading,
        errorMessage: errorMessage,
      );
}

/// Fuente de verdad de la sesión: la lee el router (`app_router.dart`) para decidir si redirige a
/// `/auth`, y la actualiza tanto el login/logout explícito del usuario como el interceptor 401 de
/// `ApiClient` (ver `core/providers.dart`).
///
/// **Los mensajes de error salen del backend, no de acá.** `describeApiError` extrae el `detail` de
/// la respuesta, que ya distingue el email tomado (409) del código de invitación faltante (403) y de
/// la contraseña corta (422). Reemplazarlos por un texto propio —como hacía la versión anterior, que
/// ante cualquier fallo del registro decía "¿el email ya existe?"— le informa al usuario un motivo
/// que puede ser falso y lo deja sin saber qué corregir.
class AuthController extends StateNotifier<AuthState> {
  AuthController(this._authRepository) : super(AuthState.initial) {
    _checkExistingSession();
  }

  final AuthRepository _authRepository;

  Future<void> _checkExistingSession() async {
    final isAuthenticated = await _authRepository.isAuthenticated();
    if (!mounted) return;
    state = state.copyWith(isAuthenticated: isAuthenticated, isLoading: false);
  }

  Future<void> login({
    required String email,
    required String password,
    bool rememberMe = true,
  }) async {
    state = state.copyWith(isLoading: true);
    try {
      await _authRepository.login(
        email: email,
        password: password,
        rememberMe: rememberMe,
      );
      if (!mounted) return;
      state = state.copyWith(isAuthenticated: true, isLoading: false);
    } on Object catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        isAuthenticated: false,
        isLoading: false,
        errorMessage: describeApiError(error),
      );
    }
  }

  /// Crea la cuenta y, si sale bien, inicia sesión con las mismas credenciales.
  ///
  /// El login va DESPUÉS y por separado para que un fallo en cada paso se pueda contar distinto: si
  /// el alta funcionó y el login falló, la cuenta existe y volver a intentar entrar es lo correcto;
  /// decirle "no se pudo registrar" mandaría a crear una cuenta que ya está creada.
  Future<void> register({
    required String email,
    required String password,
    String? inviteCode,
    bool rememberMe = true,
  }) async {
    state = state.copyWith(isLoading: true);
    try {
      await _authRepository.register(
        email: email,
        password: password,
        inviteCode: inviteCode,
      );
    } on Object catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        errorMessage: describeApiError(error),
      );
      return;
    }

    await login(email: email, password: password, rememberMe: rememberMe);
    if (!mounted) return;
    if (!state.isAuthenticated && state.errorMessage != null) {
      state = state.copyWith(
        errorMessage:
            'La cuenta se creó, pero no se pudo iniciar sesión: ${state.errorMessage}',
      );
    }
  }

  Future<void> logout() async {
    await _authRepository.logout();
    if (!mounted) return;
    state = state.copyWith(isAuthenticated: false, isLoading: false);
  }

  /// Limpia el error sin tocar el resto. Lo usa la pantalla al cambiar de pestaña: el motivo por el
  /// que falló un login no dice nada sobre el registro que el usuario está por intentar.
  void clearError() {
    if (state.errorMessage == null) return;
    state = state.copyWith();
  }
}
