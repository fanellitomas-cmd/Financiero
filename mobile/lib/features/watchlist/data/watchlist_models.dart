import '../../settings/data/exchange_type.dart';

enum AssetType { stock, crypto }

extension AssetTypeJson on AssetType {
  static AssetType fromJson(String value) => switch (value) {
        'STOCK' => AssetType.stock,
        'CRYPTO' => AssetType.crypto,
        _ => throw ArgumentError('AssetType desconocido: $value'),
      };

  String toJson() => switch (this) {
        AssetType.stock => 'STOCK',
        AssetType.crypto => 'CRYPTO',
      };
}

/// Espeja `WatchlistItemRead` (`app/schemas/watchlist.py`).
class WatchlistItem {
  const WatchlistItem({
    required this.id,
    required this.ticker,
    required this.assetType,
    required this.alertThresholdPct,
    required this.enableBeginnerMode,
    required this.exchange,
  });

  factory WatchlistItem.fromJson(Map<String, dynamic> json) => WatchlistItem(
        id: json['id'] as String,
        ticker: json['ticker'] as String,
        assetType: AssetTypeJson.fromJson(json['asset_type'] as String),
        alertThresholdPct: double.parse(json['alert_threshold_pct'].toString()),
        enableBeginnerMode: json['enable_beginner_mode'] as bool,
        exchange: exchangeTypeFromWire(json['exchange'] as String?),
      );

  final String id;
  final String ticker;
  final AssetType assetType;
  final double alertThresholdPct;
  final bool enableBeginnerMode;

  /// La resuelve el backend desde su catálogo al crear el item — el cliente no la manda.
  /// `null` para cripto (no cotiza en una bolsa de acciones) y para símbolos que todavía no
  /// están en el catálogo.
  final ExchangeType? exchange;
}
