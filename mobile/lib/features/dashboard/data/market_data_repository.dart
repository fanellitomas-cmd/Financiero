import '../../../core/network/api_client.dart';
import 'market_quote.dart';

/// Envuelve `GET /api/v1/market/quotes` (`app/api/v1/market.py`) — precio y %var en vivo de
/// cada ticker de la Watchlist del usuario, para el heatmap del Dashboard.
class MarketDataRepository {
  MarketDataRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<List<TickerQuote>> getWatchlistQuotes() async {
    final response = await _apiClient.dio.get('/market/quotes');
    return (response.data as List)
        .map((item) => TickerQuote.fromJson(item as Map<String, dynamic>))
        .toList();
  }
}
