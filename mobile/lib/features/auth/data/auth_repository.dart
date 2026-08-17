import '../../../core/network/api_client.dart';
import '../../../core/storage/token_storage.dart';

/// Envuelve `POST /api/v1/auth/register` y `POST /api/v1/auth/login` (`app/api/v1/auth.py`).
///
/// **No traduce errores.** Deja pasar la `DioException` tal como viene para que la capa de arriba use
/// el `detail` que el backend ya escribió: el servidor distingue "ya existe una cuenta con ese email"
/// (409) de "esta instancia necesita un código de invitación" (403), y aplanar las dos cosas en un
/// mensaje propio sería reemplazar un motivo real por una suposición.
class AuthRepository {
  AuthRepository(this._apiClient, this._tokenStorage);

  final ApiClient _apiClient;
  final TokenStorage _tokenStorage;

  /// Crea la cuenta. **No** deja sesión iniciada: el login es un paso aparte.
  ///
  /// `inviteCode` viaja solo cuando tiene contenido. Mandar la clave en `null` sería fijarla en null y
  /// el schema del backend la rechazaría; omitirla es lo que permite que una instancia con registro
  /// abierto siga funcionando sin el campo.
  Future<void> register({
    required String email,
    required String password,
    String? inviteCode,
  }) async {
    final trimmed = inviteCode?.trim();
    await _apiClient.dio.post(
      '/auth/register',
      data: {
        'email': email,
        'password': password,
        if (trimmed != null && trimmed.isNotEmpty) 'invite_code': trimmed,
      },
    );
  }

  Future<void> login({
    required String email,
    required String password,
    bool rememberMe = true,
  }) async {
    final response = await _apiClient.dio.post(
      '/auth/login',
      data: {'email': email, 'password': password},
    );
    final accessToken = response.data['access_token'] as String;
    await _tokenStorage.saveAccessToken(accessToken, persist: rememberMe);
  }

  Future<void> logout() => _tokenStorage.clear();

  Future<bool> isAuthenticated() async =>
      (await _tokenStorage.readAccessToken()) != null;
}
