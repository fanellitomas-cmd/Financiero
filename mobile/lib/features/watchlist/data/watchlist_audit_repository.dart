import '../../../core/network/api_client.dart';
import 'portfolio_audit.dart';

/// Envuelve `GET/POST /api/v1/watchlist/audit` (`app/api/v1/watchlist_audit.py`).
///
/// El endpoint siempre responde 200 con estructura válida: una watchlist vacía, un catálogo sin
/// sectores o un entorno sin credenciales de IA devuelven la auditoría con los bloques que se
/// pudieron armar más `availability` y `degradation_reason`. Es decir que este repositorio casi
/// nunca lanza, y el estado degradado se maneja mirando los flags, no capturando excepciones.
///
/// Los dos verbos NO son lo mismo y por eso son dos métodos y no un flag:
///   - `get` respeta la caché del backend (TTL de una hora, invalidada sola si cambia la
///     composición de la watchlist). Es lo que se usa al abrir la pantalla.
///   - `refresh` recalcula: una llamada al modelo, más una al proveedor de fundamentales por
///     símbolo nuevo y una al de precios por símbolo. Es un gesto explícito del usuario.
class WatchlistAuditRepository {
  WatchlistAuditRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<PortfolioAudit> getAudit() async {
    final response = await _apiClient.dio.get('/watchlist/audit');
    return PortfolioAudit.fromJson(response.data as Map<String, dynamic>);
  }

  Future<PortfolioAudit> refreshAudit() async {
    final response = await _apiClient.dio.post('/watchlist/audit');
    return PortfolioAudit.fromJson(response.data as Map<String, dynamic>);
  }
}
