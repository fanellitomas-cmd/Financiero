import '../../../core/network/api_client.dart';
import 'ohlc_data.dart';

/// Envuelve `GET /api/v1/market/history/{ticker}` (`app/api/v1/market.py`) — velas diarias OHLC
/// para el chart de la Ficha.
///
/// El endpoint siempre responde 200: un proveedor caído o sin configurar llega como `bars: []` más
/// un `degradation_reason`, no como un error HTTP. Eso significa que este repositorio casi nunca
/// lanza, y que el estado "sin histórico" se maneja mirando `bars`, no capturando excepciones.
class HistoryRepository {
  HistoryRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<TickerHistory> getHistory(String ticker, {int days = 30}) async {
    final response = await _apiClient.dio.get(
      '/market/history/$ticker',
      queryParameters: {'days': days},
    );
    return TickerHistory.fromJson(response.data as Map<String, dynamic>);
  }
}
