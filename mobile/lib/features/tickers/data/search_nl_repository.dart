import 'package:dio/dio.dart';

import '../../../core/network/api_client.dart';
import 'nl_search_result.dart';

/// Envuelve `POST /api/v1/tickers/search-nl` (`app/api/v1/tickers.py`) — la búsqueda conversacional.
///
/// El endpoint siempre responde 200 con estructura válida: sin credenciales de IA cae a búsqueda
/// por texto y sin proveedor de fundamentales declara los criterios numéricos sin aplicar. Es decir
/// que este repositorio casi nunca lanza, y el estado degradado se maneja mirando `criteriaSource`
/// y `unappliedCriteria`, no capturando excepciones.
///
/// Es POST y no GET aunque sea una lectura: la consulta es texto libre y la operación gasta una
/// llamada al modelo. `cancelToken` existe porque cada búsqueda es cara — si el usuario reformula
/// antes de que llegue la anterior, conviene abandonarla.
class SearchNlRepository {
  SearchNlRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<NlSearchResult> search(
    String query, {
    int limit = 20,
    CancelToken? cancelToken,
  }) async {
    final response = await _apiClient.dio.post(
      '/tickers/search-nl',
      data: {'query': query, 'limit': limit},
      cancelToken: cancelToken,
    );
    return NlSearchResult.fromJson(response.data as Map<String, dynamic>);
  }
}
