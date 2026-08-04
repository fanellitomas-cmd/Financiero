import '../../settings/data/exchange_type.dart';

/// Tono de la jornada según el modelo. Espeja `sentiment_label` de
/// `app/schemas/market.py::MarketSentiment`, que el backend valida contra este mismo conjunto
/// antes de responder (no confía en que el proveedor respete el `response_schema`).
enum MarketSentimentLabel { alcista, neutral, bajista }

/// `null` ante un label desconocido en vez de lanzar: si el backend agregara un tono nuevo, la
/// card tiene que seguir mostrando los movers y la narrativa en vez de crashear el Dashboard.
/// Se pierde el chip de sentimiento, que es lo accesorio.
MarketSentimentLabel? marketSentimentFromWire(String? value) => switch (value) {
      'ALCISTA' => MarketSentimentLabel.alcista,
      'NEUTRAL' => MarketSentimentLabel.neutral,
      'BAJISTA' => MarketSentimentLabel.bajista,
      _ => null,
    };

class MarketSentiment {
  const MarketSentiment({required this.label, required this.confidencePct});

  factory MarketSentiment.fromJson(Map<String, dynamic> json) =>
      MarketSentiment(
        label: marketSentimentFromWire(json['label'] as String?),
        confidencePct: (json['confidence_pct'] as num?)?.toDouble(),
      );

  final MarketSentimentLabel? label;
  final double? confidencePct;
}

/// Un ticker entre las mayores subas o bajas de la jornada. Espeja `MarketMoverOut`.
///
/// `exchange` es nullable porque el endpoint de movers de Polygon no la trae y el backend la
/// resuelve cruzando contra su catálogo local; además, `exchangeTypeFromWire` devuelve `null`
/// para `OTHER`, que es una bolsa real que el selector todavía no ofrece.
class MarketMover {
  const MarketMover({
    required this.ticker,
    required this.name,
    required this.exchange,
    required this.lastPrice,
    required this.dayChangePct,
  });

  factory MarketMover.fromJson(Map<String, dynamic> json) => MarketMover(
        ticker: json['ticker'] as String,
        name: json['name'] as String?,
        exchange: exchangeTypeFromWire(json['exchange'] as String?),
        lastPrice: (json['last_price'] as num?)?.toDouble(),
        dayChangePct: (json['day_change_pct'] as num?)?.toDouble(),
      );

  final String ticker;
  final String? name;
  final ExchangeType? exchange;
  final double? lastPrice;
  final double? dayChangePct;
}

/// Espeja `MarketSummary` (`app/schemas/market.py`) — respuesta de `GET /api/v1/market/summary`.
///
/// Los datos duros (`topGainers`/`topLosers`) y la narrativa (`headline`, `keyPoints`,
/// `sentiment`) están separados porque el backend degrada cada uno por su cuenta: sin Gemini
/// configurado llegan los movers con `aiNarrativeAvailable == false` y un `degradationReason`
/// legible. La UI muestra lo que sí hay y el motivo de lo que falta — nunca esconde la card
/// entera ni presenta un resumen vacío como si el mercado estuviera tranquilo.
class MarketSummary {
  const MarketSummary({
    required this.generatedAt,
    required this.exchanges,
    required this.topGainers,
    required this.topLosers,
    required this.headline,
    required this.keyPoints,
    required this.sentiment,
    required this.aiNarrativeAvailable,
    required this.marketDataAvailable,
    required this.servedFromCache,
    required this.degradationReason,
  });

  factory MarketSummary.fromJson(Map<String, dynamic> json) => MarketSummary(
        generatedAt: DateTime.parse(json['generated_at'] as String),
        exchanges: [
          for (final raw in json['exchanges'] as List)
            if (exchangeTypeFromWire(raw as String?) case final exchange?)
              exchange,
        ],
        topGainers: _movers(json['top_gainers']),
        topLosers: _movers(json['top_losers']),
        headline: json['headline'] as String?,
        keyPoints: [
          for (final point in json['key_points'] as List) point as String,
        ],
        sentiment: json['sentiment'] == null
            ? null
            : MarketSentiment.fromJson(
                json['sentiment'] as Map<String, dynamic>),
        aiNarrativeAvailable: json['ai_narrative_available'] as bool,
        marketDataAvailable: json['market_data_available'] as bool,
        servedFromCache: json['served_from_cache'] as bool,
        degradationReason: json['degradation_reason'] as String?,
      );

  static List<MarketMover> _movers(Object? raw) => [
        for (final item in raw as List)
          MarketMover.fromJson(item as Map<String, dynamic>),
      ];

  final DateTime generatedAt;
  final List<ExchangeType> exchanges;

  final List<MarketMover> topGainers;
  final List<MarketMover> topLosers;

  final String? headline;
  final List<String> keyPoints;
  final MarketSentiment? sentiment;

  final bool aiNarrativeAvailable;
  final bool marketDataAvailable;
  final bool servedFromCache;
  final String? degradationReason;

  /// `true` cuando no hay absolutamente nada que mostrar (ni movers ni narrativa). Distinto de
  /// `!marketDataAvailable`: sin datos de mercado igual puede haber un motivo que vale la pena
  /// mostrarle al usuario.
  bool get isEmpty =>
      topGainers.isEmpty && topLosers.isEmpty && !aiNarrativeAvailable;
}
