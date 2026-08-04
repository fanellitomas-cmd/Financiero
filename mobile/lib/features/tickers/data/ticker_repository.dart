import 'package:dio/dio.dart';

import '../../../core/network/api_client.dart';
import '../../settings/data/exchange_type.dart';
import 'ticker.dart';

/// Envuelve `GET /api/v1/tickers` (`app/api/v1/tickers.py`) — el catálogo de acciones con
/// filtro por bolsa, búsqueda por símbolo o nombre, y paginación.
class TickerRepository {
  TickerRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<TickerPage> search({
    ExchangeType? exchange,
    String? query,
    int limit = 20,
    int offset = 0,
    CancelToken? cancelToken,
  }) async {
    final response = await _apiClient.dio.get(
      '/tickers',
      queryParameters: {
        if (exchange != null) 'exchange': exchange.wireValue,
        if (query != null && query.isNotEmpty) 'q': query,
        'limit': limit,
        'offset': offset,
      },
      cancelToken: cancelToken,
    );
    return TickerPage.fromJson(response.data as Map<String, dynamic>);
  }
}
