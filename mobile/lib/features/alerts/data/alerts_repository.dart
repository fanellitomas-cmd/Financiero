import '../../../core/network/api_client.dart';
import 'alert_history_models.dart';

/// Envuelve `GET /api/v1/alerts` (`app/api/v1/alerts.py`) — paginado, ya filtrado del lado
/// del backend a los tickers de la Watchlist del usuario autenticado.
class AlertsRepository {
  AlertsRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<AlertHistoryPage> list(
      {required int limit, required int offset}) async {
    final response = await _apiClient.dio.get(
      '/alerts',
      queryParameters: {'limit': limit, 'offset': offset},
    );
    return AlertHistoryPage.fromJson(response.data as Map<String, dynamic>);
  }
}
