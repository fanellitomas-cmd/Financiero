import 'package:financiero_app/features/dashboard/data/market_summary.dart';
import 'package:financiero_app/features/settings/data/exchange_type.dart';
import 'package:flutter_test/flutter_test.dart';

/// El parseo se testea contra payloads con la forma EXACTA que devuelve
/// `app/schemas/market.py::MarketSummary`, incluidos los estados degradados: el contrato del
/// backend es que los movers y la narrativa fallan por separado, y si el cliente no supiera leer
/// "movers sin narrativa" mostraría la card vacía justo cuando sí hay algo que mostrar.
Map<String, dynamic> _payload({
  List<Map<String, dynamic>> gainers = const [],
  List<Map<String, dynamic>> losers = const [],
  String? headline,
  List<String> keyPoints = const [],
  Map<String, dynamic>? sentiment,
  bool aiNarrativeAvailable = false,
  bool marketDataAvailable = false,
  bool servedFromCache = false,
  String? degradationReason,
}) =>
    {
      'generated_at': '2026-08-04T17:30:00Z',
      'exchanges': ['NASDAQ', 'NYSE'],
      'top_gainers': gainers,
      'top_losers': losers,
      'headline': headline,
      'key_points': keyPoints,
      'sentiment': sentiment,
      'ai_narrative_available': aiNarrativeAvailable,
      'market_data_available': marketDataAvailable,
      'served_from_cache': servedFromCache,
      'degradation_reason': degradationReason,
    };

Map<String, dynamic> _mover(
  String ticker, {
  String? name,
  String? exchange = 'NASDAQ',
  double? change = 5.0,
  double? price = 100.0,
}) =>
    {
      'ticker': ticker,
      'name': name,
      'exchange': exchange,
      'last_price': price,
      'day_change_pct': change,
    };

void main() {
  group('MarketSummary.fromJson', () {
    test('parsea el caso completo con narrativa y movers', () {
      final summary = MarketSummary.fromJson(
        _payload(
          gainers: [_mover('NVDA', name: 'NVIDIA Corporation', change: 7.2)],
          losers: [_mover('JPM', exchange: 'NYSE', change: -3.1)],
          headline: 'Jornada mixta.',
          keyPoints: ['Tecnología en alza.', 'Financieras en baja.'],
          sentiment: {'label': 'ALCISTA', 'confidence_pct': 72.0},
          aiNarrativeAvailable: true,
          marketDataAvailable: true,
        ),
      );

      expect(summary.generatedAt.isUtc, isTrue);
      expect(summary.exchanges, [ExchangeType.nasdaq, ExchangeType.nyse]);
      expect(summary.headline, 'Jornada mixta.');
      expect(summary.keyPoints, hasLength(2));
      expect(summary.sentiment?.label, MarketSentimentLabel.alcista);
      expect(summary.sentiment?.confidencePct, 72.0);
      expect(summary.aiNarrativeAvailable, isTrue);
      expect(summary.isEmpty, isFalse);

      expect(summary.topGainers.single.ticker, 'NVDA');
      expect(summary.topGainers.single.name, 'NVIDIA Corporation');
      expect(summary.topGainers.single.exchange, ExchangeType.nasdaq);
      expect(summary.topLosers.single.exchange, ExchangeType.nyse);
      expect(summary.topLosers.single.dayChangePct, -3.1);
    });

    test('parsea movers sin narrativa (Gemini no configurado)', () {
      // El caso que más importa: si esto se leyera como "vacío", la card esconderría datos
      // reales de mercado solo porque falta la parte de IA.
      final summary = MarketSummary.fromJson(
        _payload(
          gainers: [_mover('NVDA')],
          marketDataAvailable: true,
          degradationReason: 'falta GEMINI_API_KEY',
        ),
      );

      expect(summary.aiNarrativeAvailable, isFalse);
      expect(summary.headline, isNull);
      expect(summary.sentiment, isNull);
      expect(summary.topGainers, hasLength(1));
      expect(summary.degradationReason, 'falta GEMINI_API_KEY');
      expect(summary.isEmpty, isFalse);
    });

    test('isEmpty solo cuando no hay ni movers ni narrativa', () {
      final nothing = MarketSummary.fromJson(
        _payload(degradationReason: 'sin datos del proveedor'),
      );
      expect(nothing.isEmpty, isTrue);
      // Aun sin datos, el motivo se conserva: es lo único que la card tiene para mostrar.
      expect(nothing.degradationReason, isNotNull);
    });

    test('un label de sentimiento desconocido no rompe el parseo', () {
      // Si el backend agregara un tono nuevo, la card debe seguir mostrando movers y narrativa;
      // lo único que se pierde es el chip, que es lo accesorio.
      final summary = MarketSummary.fromJson(
        _payload(
          gainers: [_mover('NVDA')],
          headline: 'Algo pasó.',
          sentiment: {'label': 'EUFÓRICO', 'confidence_pct': 90.0},
          aiNarrativeAvailable: true,
          marketDataAvailable: true,
        ),
      );

      expect(summary.sentiment, isNotNull);
      expect(summary.sentiment?.label, isNull);
      expect(summary.headline, 'Algo pasó.');
      expect(summary.topGainers, hasLength(1));
    });

    test('un mover de una bolsa que el selector no ofrece queda sin bolsa', () {
      // `OTHER` es una bolsa real del backend (NYSE Arca, Cboe…) que el selector todavía no
      // muestra: se parsea a `null`, no se descarta el mover ni se lanza.
      final summary = MarketSummary.fromJson(
        _payload(
          gainers: [_mover('ARCA1', exchange: 'OTHER')],
          marketDataAvailable: true,
        ),
      );

      expect(summary.topGainers.single.ticker, 'ARCA1');
      expect(summary.topGainers.single.exchange, isNull);
    });

    test('un mover sin precio ni variación se parsea con nulls', () {
      // El backend manda `null` cuando el proveedor no dio el dato; convertirlo a 0 lo haría
      // pasar por un movimiento plano real.
      final summary = MarketSummary.fromJson(
        _payload(
          gainers: [_mover('SINDATO', change: null, price: null)],
          marketDataAvailable: true,
        ),
      );

      expect(summary.topGainers.single.dayChangePct, isNull);
      expect(summary.topGainers.single.lastPrice, isNull);
    });

    test('servedFromCache se propaga', () {
      final summary = MarketSummary.fromJson(
        _payload(marketDataAvailable: true, servedFromCache: true),
      );
      expect(summary.servedFromCache, isTrue);
    });
  });
}
