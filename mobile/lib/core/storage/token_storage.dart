import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persistencia del JWT emitido por `POST /api/v1/auth/login`. Usa el keychain/keystore
/// nativo (vía `flutter_secure_storage`) en vez de `SharedPreferences` — el access token no
/// debe quedar en texto plano en disco.
class TokenStorage {
  TokenStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _accessTokenKey = 'financiero_access_token';

  final FlutterSecureStorage _storage;

  Future<void> saveAccessToken(String token) =>
      _storage.write(key: _accessTokenKey, value: token);

  Future<String?> readAccessToken() => _storage.read(key: _accessTokenKey);

  Future<void> clear() => _storage.delete(key: _accessTokenKey);
}
