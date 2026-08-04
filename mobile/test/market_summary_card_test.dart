import 'dart:async';

import 'package:financiero_app/core/theme/app_theme.dart';
import 'package:financiero_app/features/dashboard/data/market_summary.dart';
import 'package:financiero_app/features/dashboard/presentation/market_summary_controller.dart';
import 'package:financiero_app/features/dashboard/widgets/market_summary_card.dart';
import 'package:financiero_app/features/settings/data/exchange_type.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Se sobreescribe `marketSummaryProvider` directo (no el repositorio ni Dio): lo que se prueba
/// acá es cómo la card reacciona a cada estado — cargando, error, y los tres grados de
/// degradación del backend — sin nada de transporte en el medio.
MarketSummary _summary({
  List<MarketMover> gainers = const [],
  List<MarketMover> losers = const [],
  String? headline,
  List<String> keyPoints = const [],
  MarketSentiment? sentiment,
  bool aiNarrativeAvailable = false,
  bool marketDataAvailable = false,
  String? degradationReason,
}) =>
    MarketSummary(
      generatedAt: DateTime.utc(2026, 8, 4, 17, 30),
      exchanges: const [ExchangeType.nasdaq, ExchangeType.nyse],
      topGainers: gainers,
      topLosers: losers,
      headline: headline,
      keyPoints: keyPoints,
      sentiment: sentiment,
      aiNarrativeAvailable: aiNarrativeAvailable,
      marketDataAvailable: marketDataAvailable,
      servedFromCache: false,
      degradationReason: degradationReason,
    );

MarketMover _mover(String ticker, double? change) => MarketMover(
      ticker: ticker,
      name: '$ticker Inc.',
      exchange: ExchangeType.nasdaq,
      lastPrice: 100,
      dayChangePct: change,
    );

/// `scopeKey` fuerza un `ProviderScope` nuevo cuando un mismo test monta la card más de una vez:
/// sin key, Flutter reutiliza el elemento del scope anterior y el override no vuelve a
/// ejecutarse, así que la segunda iteración seguiría mostrando los datos de la primera.
Future<void> _pumpCard(
  WidgetTester tester,
  FutureOr<MarketSummary> Function() result, {
  Key? scopeKey,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      key: scopeKey,
      overrides: [marketSummaryProvider.overrideWith((ref) => result())],
      child: MaterialApp(
        theme: AppTheme.dark,
        home: const Scaffold(
          body: SingleChildScrollView(child: MarketSummaryCard()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('muestra narrativa, puntos clave y chip de sentimiento', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      () => _summary(
        gainers: [_mover('NVDA', 7.2)],
        losers: [_mover('JPM', -3.1)],
        headline: 'Jornada mixta en Nasdaq.',
        keyPoints: const ['Tecnología en alza.', 'Financieras en baja.'],
        sentiment: const MarketSentiment(
          label: MarketSentimentLabel.alcista,
          confidencePct: 72,
        ),
        aiNarrativeAvailable: true,
        marketDataAvailable: true,
      ),
    );

    expect(find.text('Jornada mixta en Nasdaq.'), findsOneWidget);
    expect(find.text('• Tecnología en alza.'), findsOneWidget);
    expect(find.textContaining('ALCISTA'), findsOneWidget);
    expect(find.text('Mayores subas'), findsOneWidget);
    expect(find.text('Mayores bajas'), findsOneWidget);
    expect(find.text('NVDA'), findsOneWidget);
    expect(find.text('+7.20%'), findsOneWidget);
    expect(find.text('-3.10%'), findsOneWidget);
  });

  testWidgets(
    'sin narrativa muestra los movers y el motivo, no una card vacía',
    (tester) async {
      // Esta es la degradación que la card existe para manejar: Gemini sin configurar no debe
      // esconder datos de mercado que sí llegaron.
      await _pumpCard(
        tester,
        () => _summary(
          gainers: [_mover('NVDA', 7.2)],
          marketDataAvailable: true,
          degradationReason: 'falta GEMINI_API_KEY en .env',
        ),
      );

      expect(find.text('NVDA'), findsOneWidget);
      expect(find.text('Mayores subas'), findsOneWidget);
      expect(find.textContaining('falta GEMINI_API_KEY'), findsOneWidget);
      // Sin sentimiento no se pinta el chip.
      expect(find.textContaining('ALCISTA'), findsNothing);
      expect(find.textContaining('NEUTRAL'), findsNothing);
    },
  );

  testWidgets('sin datos de mercado muestra solo el motivo', (tester) async {
    await _pumpCard(
      tester,
      () => _summary(
        degradationReason: 'el proveedor de precios no devolvió resultados',
      ),
    );

    expect(find.textContaining('no devolvió resultados'), findsOneWidget);
    expect(find.text('Mayores subas'), findsNothing);
  });

  testWidgets('un error del request se muestra con opción de reintentar', (
    tester,
  ) async {
    await _pumpCard(
        tester, () => Future<MarketSummary>.error(StateError('boom')));

    expect(find.text('Reintentar'), findsOneWidget);
    // El encabezado se mantiene: la card no desaparece del Dashboard por un error.
    expect(find.text('Resumen del día'), findsOneWidget);
  });

  testWidgets('mientras carga avisa que está compilando el resumen', (
    tester,
  ) async {
    // Un Completer que nunca resuelve deja la card fija en el estado de carga.
    final pending = Completer<MarketSummary>();
    addTearDown(() => pending.complete(_summary()));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          marketSummaryProvider.overrideWith((ref) => pending.future),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: MarketSummaryCard()),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('Compilando'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('el chip de sentimiento usa el color semántico de cada tono', (
    tester,
  ) async {
    // Verde/rojo son los tokens de dirección de mercado; el neutral va en cian porque el ámbar
    // se lee como advertencia y "mercado lateral" no lo es.
    for (final (label, expected) in [
      (MarketSentimentLabel.alcista, AppTheme.bullish),
      (MarketSentimentLabel.bajista, AppTheme.bearish),
      (MarketSentimentLabel.neutral, AppTheme.accent),
    ]) {
      await _pumpCard(
        tester,
        () => _summary(
          headline: 'Titular.',
          sentiment: MarketSentiment(label: label, confidencePct: null),
          aiNarrativeAvailable: true,
          marketDataAvailable: true,
        ),
        scopeKey: ValueKey(label),
      );

      final text = tester.widget<Text>(
        find.textContaining(RegExp('ALCISTA|BAJISTA|NEUTRAL')),
      );
      expect(text.style?.color, expected, reason: 'tono $label');
    }
  });

  testWidgets('un mover sin variación se pinta neutro y no como suba', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      () => _summary(
          gainers: [_mover('SINDATO', null)], marketDataAvailable: true),
    );

    final change = tester.widget<Text>(find.text('—'));
    // Teñirlo de verde afirmaría una dirección que no se tiene.
    expect(change.style?.color, AppTheme.textMuted);
  });
}
