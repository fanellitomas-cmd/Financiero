import '../../../core/network/api_client.dart';
import 'deep_intelligence.dart';

/// Envuelve `GET /api/v1/tickers/{ticker}/intelligence` (`app/api/v1/tickers.py`) — fundamentales,
/// síntesis de reportes oficiales y proyecciones multi-horizonte.
///
/// El endpoint siempre responde 200 con estructura válida: un entorno sin credenciales devuelve los
/// tres bloques en `UNAVAILABLE` con su motivo, no un error HTTP. Eso significa que este repositorio
/// casi nunca lanza, y que el estado degradado se maneja mirando `availability`, no capturando
/// excepciones.
///
/// El backend cachea por ticker con TTL de una hora (es la operación más cara del sistema: una
/// llamada al LLM más cuatro a proveedores), así que pedirla de nuevo es barato. `forceRefresh`
/// existe para el gesto explícito del usuario, que sí debe saltear la caché.
class DeepResearchRepository {
  DeepResearchRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<DeepIntelligence> getIntelligence(
    String ticker, {
    bool forceRefresh = false,
  }) async {
    final response = await _apiClient.dio.get(
      '/tickers/$ticker/intelligence',
      queryParameters: forceRefresh ? {'force_refresh': true} : null,
    );
    return DeepIntelligence.fromJson(response.data as Map<String, dynamic>);
  }
}
