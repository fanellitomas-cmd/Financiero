/// Configuración de entorno de la app. Se inyecta por `--dart-define` en build/run, nunca
/// hardcodeada — igual que el backend nunca hardcodea credenciales fuera de `AppSettings`.
///
/// Ejemplo (emulador Android, backend corriendo en el host):
///   flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000/api/v1 \
///               --dart-define=WS_BASE_URL=ws://10.0.2.2:8000/api/v1
class AppConfig {
  const AppConfig({required this.apiBaseUrl, required this.wsBaseUrl});

  final String apiBaseUrl;
  final String wsBaseUrl;

  /// `10.0.2.2` es el alias del emulador de Android hacia `localhost` del host — default
  /// razonable para desarrollo local contra `uvicorn app.main:app --reload`.
  static const AppConfig defaultConfig = AppConfig(
    apiBaseUrl: String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'http://10.0.2.2:8000/api/v1',
    ),
    wsBaseUrl: String.fromEnvironment(
      'WS_BASE_URL',
      defaultValue: 'ws://10.0.2.2:8000/api/v1',
    ),
  );
}
