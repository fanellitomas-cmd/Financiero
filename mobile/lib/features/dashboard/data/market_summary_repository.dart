import '../../../core/network/api_client.dart';
import 'market_summary.dart';

/// Envuelve `GET /api/v1/market/summary` (`app/api/v1/market.py`) — mayores subas y bajas de la
/// jornada más el resumen ejecutivo del agente.
///
/// El backend cachea la respuesta en memoria (TTL configurable, ver `MarketSummaryService`), así
/// que pedirla no cuesta una llamada al modelo: es seguro refrescar el Dashboard sin miedo a
/// gastar cuota. `forceRefresh` existe para el pull-to-refresh explícito del usuario, que sí
/// debe saltear la caché.
class MarketSummaryRepository {
  MarketSummaryRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<MarketSummary> getSummary({bool forceRefresh = false}) async {
    final response = await _apiClient.dio.get(
      '/market/summary',
      queryParameters: forceRefresh ? {'force_refresh': true} : null,
    );
    return MarketSummary.fromJson(response.data as Map<String, dynamic>);
  }
}
