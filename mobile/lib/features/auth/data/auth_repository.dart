import '../../../core/network/api_client.dart';
import '../../../core/storage/token_storage.dart';

/// Envuelve `POST /api/v1/auth/register` y `POST /api/v1/auth/login` (`app/api/v1/auth.py`).
class AuthRepository {
  AuthRepository(this._apiClient, this._tokenStorage);

  final ApiClient _apiClient;
  final TokenStorage _tokenStorage;

  Future<void> register(
      {required String email, required String password}) async {
    await _apiClient.dio.post(
      '/auth/register',
      data: {'email': email, 'password': password},
    );
  }

  Future<void> login({required String email, required String password}) async {
    final response = await _apiClient.dio.post(
      '/auth/login',
      data: {'email': email, 'password': password},
    );
    final accessToken = response.data['access_token'] as String;
    await _tokenStorage.saveAccessToken(accessToken);
  }

  Future<void> logout() => _tokenStorage.clear();

  Future<bool> isAuthenticated() async =>
      (await _tokenStorage.readAccessToken()) != null;
}
