enum QuoteStatus { ok, noDisponible, errorApi, stale }

QuoteStatus quoteStatusFromJson(String value) => switch (value) {
      'OK' => QuoteStatus.ok,
      'NO_DISPONIBLE' => QuoteStatus.noDisponible,
      'ERROR_API' => QuoteStatus.errorApi,
      'STALE' => QuoteStatus.stale,
      _ => throw ArgumentError('QuoteStatus desconocido: $value'),
    };

/// Espeja `TickerQuote` (`app/schemas/market.py`). `status != ok` no es un error del
/// request completo (`GET /market/quotes` sigue devolviendo 200): es ESE ticker puntual el
/// que no tiene precio disponible ahora — el tile del heatmap se degrada individualmente,
/// no toda la pantalla (ver `MarketDataService._get_quote` del lado del backend).
class TickerQuote {
  const TickerQuote({
    required this.ticker,
    required this.lastPrice,
    required this.dayChangePct,
    required this.status,
  });

  factory TickerQuote.fromJson(Map<String, dynamic> json) => TickerQuote(
        ticker: json['ticker'] as String,
        lastPrice: (json['last_price'] as num?)?.toDouble(),
        dayChangePct: (json['day_change_pct'] as num?)?.toDouble(),
        status: quoteStatusFromJson(json['status'] as String),
      );

  final String ticker;
  final double? lastPrice;
  final double? dayChangePct;
  final QuoteStatus status;
}
