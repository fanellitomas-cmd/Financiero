import 'package:intl/intl.dart';

import '../../../core/network/api_client.dart';
import 'corporate_models.dart';

/// Envuelve `/api/v1/corporate/*` (`app/api/v1/corporate.py`) — las cuatro vistas del Hub
/// Corporativo.
///
/// Un repositorio para las cuatro y no uno por vista: comparten el prefijo, el contrato de
/// degradación y la caché del backend. Separarlos multiplicaría por cuatro el mismo envoltorio.
///
/// **Ningún método lanza por falta de datos.** Los cuatro endpoints responden 200 con su estructura
/// válida, `availability` y un motivo legible incluso sin credenciales, así que acá solo se parsea.
/// Lo único que llega como excepción es un problema de transporte o de sesión.
class CorporateRepository {
  CorporateRepository(this._apiClient);

  final ApiClient _apiClient;

  /// El formato que espera el backend para `from`/`to` (`date` de Pydantic).
  static final DateFormat _wireDate = DateFormat('yyyy-MM-dd');

  /// Balances programados y publicados en un rango.
  ///
  /// `ticker` y `sector` no se combinan del lado del servidor: si van los dos, gana `ticker`. Se
  /// deja pasar tal cual en vez de validarlo acá para que la app no tenga una segunda copia de esa
  /// regla que se pueda desincronizar de la del backend.
  Future<EarningsCalendar> earningsCalendar({
    DateTime? from,
    DateTime? to,
    String? ticker,
    String? sector,
  }) async {
    final response = await _apiClient.dio.get(
      '/corporate/earnings-calendar',
      queryParameters: {
        if (from != null) 'from': _wireDate.format(from),
        if (to != null) 'to': _wireDate.format(to),
        if (ticker != null && ticker.isNotEmpty) 'ticker': ticker,
        if (sector != null && sector.isNotEmpty) 'sector': sector,
      },
    );
    return EarningsCalendar.fromJson(response.data as Map<String, dynamic>);
  }

  /// Trimestres ya publicados de un símbolo, del más reciente al más viejo.
  Future<EarningsHistory> earningsHistory(String ticker, {int limit = 8}) async {
    final response = await _apiClient.dio.get(
      '/corporate/earnings-history/$ticker',
      queryParameters: {'limit': limit},
    );
    return EarningsHistory.fromJson(response.data as Map<String, dynamic>);
  }

  /// Reportes ante la SEC.
  ///
  /// `summarize` es opt-in porque cuesta una llamada al modelo: abrir la biblioteca para ver qué
  /// presentó una empresa no debería gastarla, y quien quiere la síntesis la pide.
  Future<FilingsResponse> filings(
    String ticker, {
    int limit = 10,
    bool summarize = false,
  }) async {
    final response = await _apiClient.dio.get(
      '/corporate/filings/$ticker',
      queryParameters: {
        'limit': limit,
        if (summarize) 'summarize': true,
      },
    );
    return FilingsResponse.fromJson(response.data as Map<String, dynamic>);
  }

  /// Feed de noticias y rumores, con filtros combinables.
  ///
  /// Los enums se serializan con sus helpers (`newsCategoryToWire`) y no con `.name`: los nombres de
  /// Dart son camelCase y el backend espera `SCREAMING_CASE`, así que un `.name` daría un 422.
  Future<CorporateNewsFeed> news({
    String? ticker,
    NewsCategory? category,
    NewsSentiment? sentiment,
    int limit = 20,
  }) async {
    final response = await _apiClient.dio.get(
      '/corporate/news',
      queryParameters: {
        if (ticker != null && ticker.isNotEmpty) 'ticker': ticker,
        if (category != null) 'category': newsCategoryToWire(category),
        if (sentiment != null) 'sentiment': newsSentimentToWire(sentiment),
        'limit': limit,
      },
    );
    return CorporateNewsFeed.fromJson(response.data as Map<String, dynamic>);
  }
}
