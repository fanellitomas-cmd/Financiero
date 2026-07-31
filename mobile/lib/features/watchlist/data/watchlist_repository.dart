import '../../../core/network/api_client.dart';
import 'watchlist_models.dart';

/// Envuelve `GET/POST/DELETE /api/v1/watchlist` (`app/api/v1/watchlist.py`).
class WatchlistRepository {
  WatchlistRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<List<WatchlistItem>> list() async {
    final response = await _apiClient.dio.get('/watchlist');
    return (response.data as List)
        .map((item) => WatchlistItem.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<WatchlistItem> add({
    required String ticker,
    required AssetType assetType,
    double? alertThresholdPct,
    bool enableBeginnerMode = false,
  }) async {
    final response = await _apiClient.dio.post(
      '/watchlist',
      data: {
        'ticker': ticker,
        'asset_type': assetType.toJson(),
        if (alertThresholdPct != null)
          'alert_threshold_pct': alertThresholdPct.toString(),
        'enable_beginner_mode': enableBeginnerMode,
      },
    );
    return WatchlistItem.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> remove(String itemId) => _apiClient.dio.delete('/watchlist/$itemId');
}
