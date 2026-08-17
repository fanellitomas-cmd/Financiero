import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persistencia del JWT emitido por `POST /api/v1/auth/login`.
///
/// Usa el keychain/keystore nativo (vía `flutter_secure_storage`) en vez de `SharedPreferences` — el
/// access token no debe quedar en texto plano en disco. En Web el backend de ese paquete cifra el
/// valor antes de guardarlo, así que el mismo código sirve en los dos lados.
///
/// **Dos modos, y la diferencia es el punto de "recordar sesión":**
///
///   - `persist: true` (default) guarda el token en el almacenamiento del dispositivo. Cerrar la
///     pestaña o la app y volver mantiene la sesión.
///   - `persist: false` lo guarda **solo en memoria**. Al recargar la página o reabrir la app no hay
///     token y hay que entrar de nuevo — que es exactamente lo que alguien pide cuando destilda
///     "recordarme" en una computadora que no es la suya.
///
/// Un "no recordar" que igual escribe en disco y solo se olvida de leerlo sería una casilla decorativa:
/// el token quedaría ahí para cualquiera que abra el almacenamiento del navegador.
class TokenStorage {
  TokenStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _accessTokenKey = 'financiero_access_token';

  final FlutterSecureStorage _storage;

  /// El token de la sesión en curso cuando NO se pidió recordarla. Vive lo que vive el proceso.
  String? _inMemoryToken;

  Future<void> saveAccessToken(String token, {bool persist = true}) async {
    if (persist) {
      _inMemoryToken = null;
      await _storage.write(key: _accessTokenKey, value: token);
      return;
    }
    _inMemoryToken = token;
    // Se borra lo que hubiera quedado de una sesión anterior que sí se recordó: sin esto, destildar
    // "recordarme" dejaría vivo el token viejo y la sesión sobreviviría a la recarga igual.
    await _storage.delete(key: _accessTokenKey);
  }

  /// El token vigente. La memoria gana sobre el disco: es la sesión de esta corrida.
  Future<String?> readAccessToken() async =>
      _inMemoryToken ?? await _storage.read(key: _accessTokenKey);

  Future<void> clear() async {
    _inMemoryToken = null;
    await _storage.delete(key: _accessTokenKey);
  }
}
