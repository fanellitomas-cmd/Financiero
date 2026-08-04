import '../../settings/data/exchange_type.dart';

/// Espeja `TickerRead` (`app/schemas/ticker.py`) — una entrada del catálogo de acciones que el
/// backend sincroniza desde Polygon (`scripts/sync_tickers.py`).
class Ticker {
  const Ticker({
    required this.symbol,
    required this.name,
    required this.exchange,
    required this.primaryExchange,
    required this.assetType,
  });

  factory Ticker.fromJson(Map<String, dynamic> json) => Ticker(
        symbol: json['symbol'] as String,
        name: json['name'] as String,
        // `exchangeTypeFromWire` devuelve null para `OTHER` (el enum del cliente solo tiene
        // NASDAQ/NYSE, las dos bolsas que el producto ofrece elegir) — no es un error de
        // parseo: es un ticker de una bolsa que todavía no está en el selector.
        exchange: exchangeTypeFromWire(json['exchange'] as String?),
        primaryExchange: json['primary_exchange'] as String?,
        assetType: json['asset_type'] as String?,
      );

  final String symbol;
  final String name;

  /// `null` cuando el backend devolvió `OTHER` — ver `fromJson`.
  final ExchangeType? exchange;

  /// Código MIC crudo del proveedor (`XNAS`, `XNYS`, `ARCX`…). Se expone para poder mostrar
  /// de qué bolsa se trata cuando `exchange` es `null`, en vez de un genérico "otra".
  final String? primaryExchange;

  /// Tipo de instrumento según Polygon (`CS`, `ETF`, `ADRC`…), no el AssetType del producto.
  final String? assetType;

  /// Texto para el badge de bolsa. Cae al MIC crudo antes que a un placeholder: para un ETF de
  /// NYSE Arca es más informativo ver "ARCX" que "OTRA".
  String get exchangeLabel =>
      exchange?.displayName ?? primaryExchange ?? 'OTRA';
}

/// Espeja `TickerPage` — el catálogo es grande (~10k símbolos), así que siempre viene paginado.
class TickerPage {
  const TickerPage({required this.items, required this.total});

  factory TickerPage.fromJson(Map<String, dynamic> json) => TickerPage(
        items: (json['items'] as List)
            .map((item) => Ticker.fromJson(item as Map<String, dynamic>))
            .toList(),
        total: json['total'] as int,
      );

  final List<Ticker> items;
  final int total;
}
