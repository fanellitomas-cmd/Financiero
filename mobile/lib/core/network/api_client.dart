import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../storage/token_storage.dart';

/// Cliente HTTP único y reutilizado para toda la app — nunca se crea una instancia de `Dio`
/// por request. Mismo principio que ya sigue el backend con sus clientes HTTP de larga vida
/// (Polygon/FMP/Tavily/Gemini/FCM, ver `app/main.py`): un cliente, inyectado una vez.
///
/// Inyecta el JWT en cada request vía interceptor y, ante un 401 (token vencido/inválido),
/// limpia el token guardado y notifica a la capa de auth (`onUnauthorized`) para que redirija
/// al login — sin acoplar esta clase a la navegación.
class ApiClient {
  ApiClient({
    required AppConfig config,
    required TokenStorage tokenStorage,
    Future<void> Function()? onUnauthorized,
  })  : _tokenStorage = tokenStorage,
        _onUnauthorized = onUnauthorized,
        _dio = Dio(
          BaseOptions(
            baseUrl: config.apiBaseUrl,
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 15),
          ),
        ) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await _tokenStorage.readAccessToken();
          if (token != null) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (error, handler) async {
          if (error.response?.statusCode == 401) {
            await _tokenStorage.clear();
            await _onUnauthorized?.call();
          }
          handler.next(error);
        },
      ),
    );
  }

  final Dio _dio;
  final TokenStorage _tokenStorage;
  final Future<void> Function()? _onUnauthorized;

  Dio get dio => _dio;
}
