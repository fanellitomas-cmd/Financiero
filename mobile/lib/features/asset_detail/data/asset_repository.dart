import '../../../core/network/api_client.dart';
import '../../watchlist/data/watchlist_models.dart';
import 'push_notification_payload.dart';

/// Envuelve `GET /api/v1/assets/{ticker}` (`app/api/v1/assets.py`) — Ficha on-demand. El
/// backend responde 404 si el motor no produjo ningún análisis para el ticker (nunca hay
/// datos que mostrar, no un error transitorio), o 502/503 ante un fallo real — `ApiClient`
/// no traduce esos códigos, eso lo hace la UI vía `describeApiError` (ver
/// `core/network/api_error.dart`) para no duplicar el mapeo mensaje-por-código en cada
/// repositorio.
class AssetRepository {
  AssetRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<PushNotificationPayload> getAssetIntelligence(
    String ticker,
    AssetType assetType,
  ) async {
    final response = await _apiClient.dio.get(
      '/assets/${ticker.toUpperCase()}',
      queryParameters: {'asset_type': assetType.toJson()},
    );
    return PushNotificationPayload.fromJson(response.data as Map<String, dynamic>);
  }
}
