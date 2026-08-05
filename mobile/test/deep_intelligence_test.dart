import 'dart:async';

import 'package:financiero_app/core/theme/app_theme.dart';
import 'package:financiero_app/features/asset_detail/data/deep_intelligence.dart';
import 'package:financiero_app/features/asset_detail/presentation/deep_intelligence_controller.dart';
import 'package:financiero_app/features/asset_detail/widgets/deep_intelligence_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Payloads con la forma EXACTA de `app/schemas/intelligence.py`, incluidos los estados degradados:
/// el contrato del backend es que los tres bloques fallan por separado, y si el cliente no supiera
/// leer "fundamentales sí, síntesis no" mostraría la Ficha vacía justo cuando hay datos reales.
Map<String, dynamic> _ratio(String label, double? value, String? unit) => {
      'label': label,
      'value': value,
      'unit': unit,
    };

Map<String, dynamic> _fundamentalsJson({
  String availability = 'AVAILABLE',
  String health = 'SOLIDA',
  List<String> notes = const ['Deuda/Equity de 0.42x: apalancamiento bajo.'],
  String? degradationReason,
  bool allMissing = false,
}) =>
    {
      'availability': availability,
      'as_of': '2026-08-04T00:00:00Z',
      'period': 'TTM',
      'price_earnings': _ratio('P/E', allMissing ? null : 58.4, 'x'),
      'price_earnings_growth': _ratio('PEG', allMissing ? null : 1.18, 'x'),
      'debt_to_equity': _ratio('Deuda/Equity', allMissing ? null : 0.42, 'x'),
      'debt_to_ebitda':
          _ratio('Deuda neta/EBITDA', allMissing ? null : 0.21, 'x'),
      'free_cash_flow': _ratio(
        'Flujo de caja libre',
        allMissing ? null : 60800000000,
        'USD',
      ),
      'free_cash_flow_yield_pct': _ratio(
        'FCF yield',
        allMissing ? null : 0.019,
        '%',
      ),
      'gross_margin_pct':
          _ratio('Margen bruto', allMissing ? null : 0.749, '%'),
      'operating_margin_pct': _ratio(
        'Margen operativo',
        allMissing ? null : 0.622,
        '%',
      ),
      'return_on_equity_pct': _ratio('ROE', allMissing ? null : 0.913, '%'),
      'current_ratio': _ratio('Ratio corriente', allMissing ? null : 4.1, 'x'),
      'revenue_growth_yoy_pct': _ratio(
        'Crecimiento de ingresos YoY',
        allMissing ? null : 1.142,
        '%',
      ),
      'financial_health': health,
      'financial_health_notes': notes,
      'degradation_reason': degradationReason,
    };

Map<String, dynamic> _ragJson({
  String availability = 'AVAILABLE',
  String? degradationReason,
}) =>
    {
      'availability': availability,
      'headline': availability == 'AVAILABLE' ? 'Trimestre récord.' : null,
      'key_points': availability == 'AVAILABLE'
          ? ['Ingresos +114% YoY.', 'Margen bruto en 74,9%.']
          : <String>[],
      'risks': availability == 'AVAILABLE'
          ? ['Restricciones de exportación en evaluación.']
          : <String>[],
      'sources': availability == 'AVAILABLE'
          ? [
              {
                'ref_id': 'NEWS-1',
                'source_type': 'NEWS',
                'title': 'NVDA reporta ingresos récord',
                'url': 'https://news.example/1',
                'published_at': '2026-08-01T20:05:00Z',
              },
              {
                'ref_id': 'SEC_10K-1',
                'source_type': 'SEC_10K',
                'title': 'Referencia a 10-K de NVDA',
                'url': 'https://sec.example/doc',
                'published_at': '2026-02-21T00:00:00Z',
              },
            ]
          : <Map<String, dynamic>>[],
      'degradation_reason': degradationReason,
    };

Map<String, dynamic> _projectionsJson({
  String availability = 'AVAILABLE',
  String? degradationReason,
  String trend = 'ALCISTA',
  String confidence = 'MEDIA',
  String conviction = 'MODERADA',
  double? baseProbability = 55,
  bool includeLongTerm = true,
}) =>
    {
      'availability': availability,
      'short_term': availability == 'AVAILABLE'
          ? {
              'horizon_label': 'Corto plazo (1-14 días)',
              'trend': trend,
              'confidence': confidence,
              'argument':
                  'El guidance revisado al alza es un catalizador reciente.',
              'evidence_refs': ['NEWS-1'],
            }
          : null,
      'medium_term': availability == 'AVAILABLE'
          ? {
              'horizon_label': 'Mediano plazo (1-6 meses)',
              'base_case': {
                'label': 'BASE',
                'narrative': 'Sostiene márgenes.',
                'probability_pct': baseProbability,
              },
              'bull_case': {
                'label': 'ALCISTA',
                'narrative': 'Acelera por demanda.',
                'probability_pct': 25,
              },
              'bear_case': {
                'label': 'BAJISTA',
                'narrative': 'Compresión de múltiplos.',
                'probability_pct': 20,
              },
              'catalysts': ['Resultados del Q3'],
              'confidence': confidence,
              'evidence_refs': ['NEWS-1'],
            }
          : null,
      'long_term': availability == 'AVAILABLE' && includeLongTerm
          ? {
              'horizon_label': 'Largo plazo (1-3 años)',
              'thesis': 'Foso tecnológico en el ecosistema de software.',
              'conviction': conviction,
              'supporting_factors': ['Escala de I+D.'],
              'invalidation_triggers': ['Adopción de arquitectura abierta.'],
              'evidence_refs': ['SEC_10K-1'],
            }
          : null,
      'degradation_reason': degradationReason,
    };

Map<String, dynamic> _intelligenceJson({
  Map<String, dynamic>? fundamentals,
  Map<String, dynamic>? rag,
  Map<String, dynamic>? projections,
  bool servedFromCache = false,
  String? companyName = 'NVIDIA Corporation',
}) =>
    {
      'ticker': 'NVDA',
      'company_name': companyName,
      'generated_at': '2026-08-04T21:00:00Z',
      'fundamentals': fundamentals ?? _fundamentalsJson(),
      'rag_summary': rag ?? _ragJson(),
      'projections': projections ?? _projectionsJson(),
      'served_from_cache': servedFromCache,
    };

Future<void> _pumpSheet(
  WidgetTester tester,
  FutureOr<DeepIntelligence> Function() result, {
  Key? scopeKey,
  Size size = const Size(900, 2400),
}) async {
  // Ventana alta: la Ficha completa mide bastante más que una pantalla, y sin alto suficiente los
  // widgets de abajo no se construyen y `findsOneWidget` fallaría por layout, no por lógica.
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      key: scopeKey,
      overrides: [
        deepIntelligenceProvider('NVDA').overrideWith((ref) => result()),
      ],
      child: MaterialApp(
        theme: AppTheme.dark,
        home: const Scaffold(body: DeepIntelligenceSheet(ticker: 'NVDA')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('DeepIntelligence.fromJson', () {
    test('parsea la respuesta completa', () {
      final intel = DeepIntelligence.fromJson(_intelligenceJson());

      expect(intel.ticker, 'NVDA');
      expect(intel.companyName, 'NVIDIA Corporation');
      expect(intel.isFullyAvailable, isTrue);
      expect(intel.fundamentals.financialHealth, FinancialHealth.solida);
      expect(intel.ragSummary.keyPoints, hasLength(2));
      expect(intel.projections.shortTerm?.trend, TrendDirection.alcista);
      expect(intel.projections.longTerm?.conviction, ConvictionLevel.moderada);
    });

    test('los ratios llegan en un orden fijo, no el del JSON', () {
      // El orden de un mapa JSON no es contrato, y una grilla que cambia de orden entre requests es
      // imposible de leer.
      final intel = DeepIntelligence.fromJson(_intelligenceJson());

      expect(intel.fundamentals.ratios.map((ratio) => ratio.label).toList(), [
        'P/E',
        'PEG',
        'Deuda/Equity',
        'Deuda neta/EBITDA',
        'Flujo de caja libre',
        'FCF yield',
        'Margen bruto',
        'Margen operativo',
        'ROE',
        'Ratio corriente',
        'Crecimiento de ingresos YoY',
      ]);
    });

    test('un enum desconocido degrada al valor conservador, no lanza', () {
      // Si el backend agregara un tono nuevo, la Ficha tiene que seguir mostrándose. El fallback es
      // siempre el valor más débil: un desvío no puede fortalecer una afirmación.
      final intel = DeepIntelligence.fromJson(
        _intelligenceJson(
          fundamentals: _fundamentalsJson(health: 'EXCELENTE'),
          projections: _projectionsJson(
            trend: 'EUFÓRICO',
            confidence: 'TOTAL',
            conviction: 'ABSOLUTA',
          ),
        ),
      );

      expect(
        intel.fundamentals.financialHealth,
        FinancialHealth.indeterminada,
      );
      expect(intel.projections.shortTerm?.trend, TrendDirection.lateral);
      expect(
        intel.projections.shortTerm?.confidence,
        ConfidenceLevel.baja,
      );
      expect(intel.projections.longTerm?.conviction, ConvictionLevel.baja);
    });

    test('una availability desconocida se trata como unavailable', () {
      final intel = DeepIntelligence.fromJson(
        _intelligenceJson(
            fundamentals: _fundamentalsJson(availability: 'RARO')),
      );
      expect(
        intel.fundamentals.availability,
        DataAvailability.unavailable,
      );
    });

    test('separa reportes oficiales de noticias', () {
      final intel = DeepIntelligence.fromJson(_intelligenceJson());

      expect(intel.ragSummary.filings.map((s) => s.refId), ['SEC_10K-1']);
      expect(intel.ragSummary.news.map((s) => s.refId), ['NEWS-1']);
    });

    test('isFullyAvailable es false si algún bloque falta', () {
      final intel = DeepIntelligence.fromJson(
        _intelligenceJson(rag: _ragJson(availability: 'UNAVAILABLE')),
      );
      expect(intel.isFullyAvailable, isFalse);
    });
  });

  group('RatioValue.formatted', () {
    test('normaliza porcentajes que llegan como fracción', () {
      // FMP devuelve márgenes como fracción (0.749) o como porcentaje (74.9) según el endpoint. Sin
      // normalizar, un margen del 74,9% se mostraría como "0.75%".
      expect(
        const RatioValue(label: 'x', value: 0.749, unit: '%').formatted,
        '74.90%',
      );
      expect(
        const RatioValue(label: 'x', value: 74.9, unit: '%').formatted,
        '74.90%',
      );
    });

    test('multiplos llevan la x', () {
      expect(
        const RatioValue(label: 'x', value: 58.4, unit: 'x').formatted,
        '58.40x',
      );
    });

    test('montos en notación compacta', () {
      // Un FCF de 60.800.000.000 no entra en una celda de grilla.
      expect(
        const RatioValue(label: 'x', value: 60800000000, unit: 'USD').formatted,
        r'$60.80 MM',
      );
      expect(
        const RatioValue(label: 'x', value: -1500000, unit: 'USD').formatted,
        r'-$1.5 M',
      );
    });

    test('un valor ausente se muestra como guion, nunca como cero', () {
      // Un 0 se leería como un dato real; el guion dice "no disponible".
      const missing = RatioValue(label: 'P/E', value: null, unit: 'x');
      expect(missing.formatted, '—');
      expect(missing.isAvailable, isFalse);
    });
  });

  group('DeepIntelligenceSheet — camino completo', () {
    testWidgets('muestra las tres secciones', (tester) async {
      await _pumpSheet(
        tester,
        () => DeepIntelligence.fromJson(_intelligenceJson()),
      );

      // Sección 1
      expect(find.text('Fundamentales'), findsOneWidget);
      expect(find.text('SÓLIDA'), findsOneWidget);
      expect(find.text('P/E'), findsOneWidget);
      expect(find.text('58.40x'), findsOneWidget);
      expect(find.text('Deuda/Equity'), findsOneWidget);
      // Sección 2
      expect(find.text('Investigación sobre reportes'), findsOneWidget);
      expect(find.text('Trimestre récord.'), findsOneWidget);
      expect(find.text('Puntos clave'), findsOneWidget);
      expect(find.text('Riesgos'), findsOneWidget);
      // Sección 3
      expect(find.text('Proyecciones por horizonte'), findsOneWidget);
      expect(find.text('ALCISTA'), findsWidgets);
      expect(find.textContaining('CORTO PLAZO'), findsOneWidget);
      expect(find.textContaining('MEDIANO PLAZO'), findsOneWidget);
      expect(find.textContaining('LARGO PLAZO'), findsOneWidget);
    });

    testWidgets('el badge de salud usa el color semántico de cada veredicto', (
      tester,
    ) async {
      for (final (health, label, expected) in [
        ('SOLIDA', 'SÓLIDA', AppTheme.bullish),
        ('ADECUADA', 'ADECUADA', AppTheme.bullish),
        ('AJUSTADA', 'AJUSTADA', AppTheme.neutral),
        ('DEBIL', 'DÉBIL', AppTheme.bearish),
        // Sin diagnóstico va en gris y no en ámbar: es ausencia de veredicto, no un veredicto
        // intermedio, y el ámbar lo haría leer como "hay algo de riesgo".
        ('INDETERMINADA', 'SIN DIAGNÓSTICO', AppTheme.textMuted),
      ]) {
        await _pumpSheet(
          tester,
          () => DeepIntelligence.fromJson(
            _intelligenceJson(fundamentals: _fundamentalsJson(health: health)),
          ),
          scopeKey: ValueKey(health),
        );

        final text = tester.widget<Text>(find.text(label));
        expect(text.style?.color, expected, reason: 'veredicto $health');
      }
    });

    testWidgets('muestra las probabilidades y los catalizadores del mediano', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        () => DeepIntelligence.fromJson(_intelligenceJson()),
      );

      expect(find.text('55%'), findsOneWidget);
      expect(find.text('25%'), findsOneWidget);
      expect(find.text('20%'), findsOneWidget);
      expect(find.text('Catalizadores'), findsOneWidget);
      expect(find.text('Resultados del Q3'), findsOneWidget);
    });

    testWidgets('un escenario sin probabilidad muestra s/d y no una barra', (
      tester,
    ) async {
      // Un 0% se leería como "escenario descartado"; el modelo puede simplemente no tener base.
      await _pumpSheet(
        tester,
        () => DeepIntelligence.fromJson(
          _intelligenceJson(
            projections: _projectionsJson(baseProbability: null),
          ),
        ),
      );

      expect(find.text('s/d'), findsOneWidget);
      // Quedan las dos barras de los escenarios que sí tienen número.
      expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
    });

    testWidgets('muestra los desencadenantes de invalidación del largo plazo', (
      tester,
    ) async {
      // Es lo que distingue una tesis de una expresión de deseo: tiene que estar visible, no
      // escondido en una nota al pie.
      await _pumpSheet(
        tester,
        () => DeepIntelligence.fromJson(_intelligenceJson()),
      );

      expect(find.text('Qué la invalidaría'), findsOneWidget);
      expect(find.text('Adopción de arquitectura abierta.'), findsOneWidget);
      expect(find.text('Lo que la sostiene'), findsOneWidget);
      expect(find.textContaining('CONVICCIÓN MODERADA'), findsOneWidget);
    });

    testWidgets('los chips de referencia se muestran junto a las afirmaciones',
        (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        () => DeepIntelligence.fromJson(_intelligenceJson()),
      );

      expect(find.text('NEWS-1'), findsWidgets);
      expect(find.text('SEC_10K-1'), findsWidgets);
    });

    testWidgets('las pestañas de fuentes separan SEC de noticias', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        () => DeepIntelligence.fromJson(_intelligenceJson()),
      );

      // Arranca en SEC: un filing tiene más peso probatorio que una nota de prensa.
      expect(find.text('SEC (1)'), findsOneWidget);
      expect(find.text('Noticias (1)'), findsOneWidget);
      expect(find.text('Referencia a 10-K de NVDA'), findsOneWidget);
      expect(find.text('NVDA reporta ingresos récord'), findsNothing);

      await tester.tap(find.text('Noticias (1)'));
      await tester.pumpAndSettle();

      expect(find.text('NVDA reporta ingresos récord'), findsOneWidget);
      expect(find.text('Referencia a 10-K de NVDA'), findsNothing);
    });

    testWidgets('avisa cuando la Ficha viene de la caché del backend', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        () => DeepIntelligence.fromJson(
          _intelligenceJson(servedFromCache: true),
        ),
      );

      expect(find.text('en caché'), findsOneWidget);
    });
  });

  group('DeepIntelligenceSheet — degradación', () {
    testWidgets('un bloque UNAVAILABLE muestra banner, no una card vacía', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        () => DeepIntelligence.fromJson(
          _intelligenceJson(
            rag: _ragJson(
              availability: 'UNAVAILABLE',
              degradationReason: 'falta GEMINI_API_KEY en .env',
            ),
          ),
        ),
      );

      // La sección sigue ahí con su título: esconderla se leería como un bug.
      expect(find.text('Investigación sobre reportes'), findsOneWidget);
      expect(find.textContaining('falta GEMINI_API_KEY'), findsOneWidget);
      // Y las otras dos secciones no se ven afectadas.
      expect(find.text('Fundamentales'), findsOneWidget);
      expect(find.text('SÓLIDA'), findsOneWidget);
      expect(find.text('Proyecciones por horizonte'), findsOneWidget);
    });

    testWidgets('sin fundamentales la grilla se dibuja igual, toda en guiones',
        (
      tester,
    ) async {
      // Así el usuario ve qué ratios existen y que faltan datos, en vez de una card vacía.
      await _pumpSheet(
        tester,
        () => DeepIntelligence.fromJson(
          _intelligenceJson(
            fundamentals: _fundamentalsJson(
              availability: 'UNAVAILABLE',
              health: 'INDETERMINADA',
              notes: const [],
              degradationReason: 'falta FMP_API_KEY en .env',
              allMissing: true,
            ),
          ),
        ),
      );

      expect(find.text('P/E'), findsOneWidget);
      expect(find.text('Deuda/Equity'), findsOneWidget);
      expect(find.text('—'), findsNWidgets(11));
      expect(find.textContaining('falta FMP_API_KEY'), findsOneWidget);
    });

    testWidgets('los tres bloques caídos igual dan una Ficha legible', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        () => DeepIntelligence.fromJson(
          _intelligenceJson(
            fundamentals: _fundamentalsJson(
              availability: 'UNAVAILABLE',
              health: 'INDETERMINADA',
              notes: const [],
              degradationReason: 'sin FMP',
              allMissing: true,
            ),
            rag: _ragJson(
              availability: 'UNAVAILABLE',
              degradationReason: 'sin Gemini',
            ),
            projections: _projectionsJson(
              availability: 'UNAVAILABLE',
              degradationReason: 'sin proyecciones',
            ),
          ),
        ),
      );

      // El aviso general va una vez arriba: el usuario que arranca a leer sabe desde el principio
      // que falta algo, sin tener que scrollear hasta encontrar el hueco.
      expect(find.textContaining('Ficha está incompleta'), findsOneWidget);
      expect(find.textContaining('sin FMP'), findsOneWidget);
      expect(find.textContaining('sin Gemini'), findsOneWidget);
      expect(find.textContaining('sin proyecciones'), findsOneWidget);
    });

    testWidgets('con la Ficha completa no aparece el aviso general', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        () => DeepIntelligence.fromJson(_intelligenceJson()),
      );

      expect(find.textContaining('Ficha está incompleta'), findsNothing);
    });

    testWidgets('un horizonte faltante no deja hueco ni rompe la sección', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        () => DeepIntelligence.fromJson(
          _intelligenceJson(
            projections: _projectionsJson(includeLongTerm: false),
          ),
        ),
      );

      expect(find.textContaining('CORTO PLAZO'), findsOneWidget);
      expect(find.textContaining('MEDIANO PLAZO'), findsOneWidget);
      expect(find.textContaining('LARGO PLAZO'), findsNothing);
    });

    testWidgets('un error de red se muestra con opción de reintentar', (
      tester,
    ) async {
      // El endpoint responde 200 incluso cuando el proveedor falla, así que este camino es de red o
      // de sesión — raro, y vale reintentarlo.
      await _pumpSheet(
        tester,
        () => Future<DeepIntelligence>.error(StateError('sin conexión')),
      );

      expect(find.text('Reintentar'), findsOneWidget);
    });

    testWidgets('mientras carga avisa que puede tardar', (tester) async {
      // Un spinner mudo de varios segundos parece que se colgó: la primera compilación cruza cuatro
      // proveedores más una llamada al modelo.
      final pending = Completer<DeepIntelligence>();
      addTearDown(
        () => pending.complete(DeepIntelligence.fromJson(_intelligenceJson())),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deepIntelligenceProvider(
              'NVDA',
            ).overrideWith((ref) => pending.future),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const Scaffold(body: DeepIntelligenceSheet(ticker: 'NVDA')),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('puede tardar'), findsOneWidget);
    });
  });
}
