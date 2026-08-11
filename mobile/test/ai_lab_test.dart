import 'package:financiero_app/core/providers.dart';
import 'package:financiero_app/core/theme/app_theme.dart';
import 'package:financiero_app/core/widgets/degradation_banner.dart';
import 'package:financiero_app/features/ai_lab/data/ai_lab_models.dart';
import 'package:financiero_app/features/ai_lab/data/ai_lab_note_snippet.dart';
import 'package:financiero_app/features/ai_lab/data/ai_lab_repository.dart';
import 'package:financiero_app/features/ai_lab/presentation/ai_lab_controller.dart';
import 'package:financiero_app/features/ai_lab/widgets/analysis_blocks.dart';
import 'package:financiero_app/features/ai_lab/widgets/analysis_chat.dart';
import 'package:financiero_app/features/ai_lab/widgets/financial_analysis_tab.dart';
import 'package:financiero_app/features/ai_lab/widgets/scenario_levers.dart';
import 'package:financiero_app/features/ai_lab/widgets/scenario_simulator_tab.dart';
import 'package:financiero_app/features/ai_lab/widgets/sensitivity_matrix.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests del Laboratorio Financiero en el cliente.
///
/// Lo que este módulo promete y que es fácil de romper sin darse cuenta:
///
///   1. **`null` no es `0`.** Un margen que no se pudo calcular, un precio implícito sin múltiplo que
///      sostener y un EPS ausente se muestran como `—`. Un cero afirmaría "reportó exactamente cero".
///   2. **"Sin fijar" no es "en cero".** Un margen sin fijar deja que la inflación lo mueva; una tasa
///      sin fijar mantiene el gasto de intereses del balance. La palanca apagada NO manda la clave, y
///      mandarla en `null` sería un 422.
///   3. **El evento en texto no mueve números** y la UI lo dice antes de escribirlo y después de
///      simular.
///   4. **Las variaciones se miden contra el punto cero del modelo.** Cuando difiere del EPS
///      reportado, la pantalla muestra los dos y explica por qué.
///   5. **El precio implícito no es un precio objetivo.** Cuando no se puede calcular, se muestra el
///      motivo del backend en vez de un guion.
///   6. **Sin Gemini los números quedan** y lo único que falta es la prosa, con su motivo aparte.
///   7. **Guardar en el Lab copia la advertencia de origen** de la prosa: la nota es lo que se relee.

// --- Dobles ------------------------------------------------------------------------------------

class _FakeAiLabRepository implements AiLabRepository {
  _FakeAiLabRepository({this.analysis, this.simulation});

  FinancialAnalysisResponse? analysis;
  ScenarioSimulationResult? simulation;
  Object? analyzeFailure;
  Object? simulateFailure;

  final List<Map<String, Object?>> analyzeCalls = [];
  final List<Map<String, Object?>> simulateCalls = [];

  @override
  Future<FinancialAnalysisResponse> analyze({
    required String ticker,
    StatementPeriod period = StatementPeriod.annual,
    String? question,
    List<ConversationTurn> history = const [],
  }) async {
    analyzeCalls.add({
      'ticker': ticker,
      'period': period,
      'question': question,
      'historyLength': history.length,
    });
    if (analyzeFailure != null) throw analyzeFailure!;
    final base = analysis ?? _analysis();
    if (question == null) return base;
    // El backend devuelve el hilo con el turno agregado: el doble lo imita para que el test cubra el
    // camino real, donde el cliente NO arma el historial.
    return _analysis(
      history: [
        ...history,
        ConversationTurn(role: ConversationRole.user, content: question),
        const ConversationTurn(
          role: ConversationRole.assistant,
          content: 'El ROE viene del margen.',
        ),
      ],
    );
  }

  @override
  Future<ScenarioSimulationResult> simulate({
    required String ticker,
    StatementPeriod period = StatementPeriod.annual,
    ScenarioVariables variables = const ScenarioVariables(),
  }) async {
    simulateCalls.add({
      'ticker': ticker,
      'period': period,
      'variables': variables,
      'payload': variables.toJson(),
    });
    if (simulateFailure != null) throw simulateFailure!;
    return simulation ?? _simulation(applied: variables);
  }
}

// --- Fixtures ----------------------------------------------------------------------------------

Map<String, dynamic> _incomeJson({
  String date = '2026-01-31',
  String label = 'FY',
  double? revenue = 130500000000,
  double? grossMargin = 75.0,
  double? operatingMargin = 62.5,
  double? ebitdaMargin = 63.9,
  double? netMargin = 54.0,
  double? eps = 2.87,
  bool ebitdaDerived = true,
}) =>
    {
      'period_end': date,
      'period_label': label,
      'revenue': revenue,
      'gross_profit': 97900000000,
      'operating_income': 81500000000,
      'ebitda': 83400000000,
      'ebitda_is_derived': ebitdaDerived,
      'depreciation_amortization': 1900000000,
      'interest_expense': 250000000,
      'net_income': 70500000000,
      'eps_diluted': eps,
      'gross_margin_pct': grossMargin,
      'operating_margin_pct': operatingMargin,
      'ebitda_margin_pct': ebitdaMargin,
      'net_margin_pct': netMargin,
      'effective_tax_rate_pct': 15.0,
    };

Map<String, dynamic> _balanceJson({
  double? netDebt = -32900000000,
  double? currentRatio = 3.67,
  double? debtToEquity = 0.13,
  double? equity = 79300000000,
}) =>
    {
      'period_end': '2026-01-31',
      'period_label': 'FY',
      'total_assets': 111600000000,
      'current_assets': 80100000000,
      'cash_and_equivalents': 43200000000,
      'total_liabilities': 32300000000,
      'current_liabilities': 21800000000,
      'total_debt': 10300000000,
      'total_equity': equity,
      'current_ratio': currentRatio,
      'debt_to_equity': debtToEquity,
      'net_debt': netDebt,
      'equity_ratio_pct': 71.1,
    };

Map<String, dynamic> _cashJson({double? conversion = 86.4}) => {
      'period_end': '2026-01-31',
      'period_label': 'FY',
      'operating_cash_flow': 64100000000,
      'capital_expenditure': -3200000000,
      'free_cash_flow': 60900000000,
      'free_cash_flow_is_derived': false,
      'fcf_conversion_pct': conversion,
      'capex_to_revenue_pct': 2.5,
    };

Map<String, dynamic> _flagJson({
  String code = 'STRONG_LIQUIDITY',
  String kind = 'GREEN',
  String severity = 'INFO',
  String title = 'Liquidez holgada',
  String detail = 'Liquidez corriente de 3,67x, por encima de 2,00x.',
  double? metric = 3.67,
  double? threshold = 2.0,
}) =>
    {
      'code': code,
      'kind': kind,
      'severity': severity,
      'title': title,
      'detail': detail,
      'metric_value': metric,
      'threshold': threshold,
      'criteria_source': 'RULE',
    };

FinancialAnalysisResponse _analysis({
  List<Map<String, dynamic>>? income,
  List<Map<String, dynamic>>? balances,
  List<Map<String, dynamic>>? cashFlows,
  Map<String, dynamic>? dupont,
  List<Map<String, dynamic>>? flags,
  String? narrative = 'El ROE viene del margen y de la rotación.',
  String narrativeSource = 'LLM',
  List<ConversationTurn> history = const [],
  String availability = 'AVAILABLE',
  String? reason,
  String? narrativeReason,
  bool cached = false,
}) =>
    FinancialAnalysisResponse.fromJson({
      'ticker': 'NVDA',
      'company_name': 'NVIDIA Corporation',
      'period': 'ANNUAL',
      'generated_at': '2026-08-10T12:00:00Z',
      'income_statements': income ?? [_incomeJson()],
      'balance_sheets': balances ?? [_balanceJson()],
      'cash_flows': cashFlows ?? [_cashJson()],
      'dupont': dupont ??
          {
            'net_margin_pct': 54.0,
            'asset_turnover': 1.17,
            'equity_multiplier': 1.41,
            'roe_pct': 88.9,
            'criteria_source': 'RULE',
          },
      'flags': flags ?? [_flagJson()],
      'narrative': narrative,
      'narrative_source': narrativeSource,
      'history': history.map((turn) => turn.toJson()).toList(),
      'availability': availability,
      'degradation_reason': reason,
      'narrative_degradation_reason': narrativeReason,
      'served_from_cache': cached,
    });

Map<String, dynamic> _projectionJson({
  double? eps = 3.40,
  double? epsChange = 20.0,
  double? impliedPrice = 113.62,
  double? priceChange = 20.0,
}) =>
    {
      'revenue': 163125000000,
      'ebitda': 100335000000,
      'ebitda_margin_pct': 61.5,
      'operating_income': 98435000000,
      'interest_expense': 927000000,
      'net_income': 82933000000,
      'eps': eps,
      'free_cash_flow': 74726000000,
      'revenue_change_pct': 25.0,
      'ebitda_change_pct': 20.3,
      'eps_change_pct': epsChange,
      'free_cash_flow_change_pct': 22.7,
      'implied_price': impliedPrice,
      'implied_price_change_pct': priceChange,
    };

ScenarioSimulationResult _simulation({
  ScenarioVariables applied = const ScenarioVariables(revenueGrowthPct: 25),
  Map<String, dynamic>? projection,
  double? modelEps = 2.83,
  double? reportedEps = 2.87,
  String valuationBasis = 'PE_MULTIPLE_HELD',
  String? valuationNote =
      'El precio implícito mantiene constante el múltiplo precio/ganancias actual y mueve el EPS.',
  List<String> assumptions = const [
    'El crecimiento de ingresos que ingresás se toma como NOMINAL.',
    'Se mantienen constantes las amortizaciones, el capex y la deuda.',
  ],
  String? customEvent,
  String? narrative = 'El EPS sube y el precio implícito acompaña.',
  String availability = 'AVAILABLE',
  String? reason,
  String? narrativeReason,
  List<Map<String, dynamic>>? sensitivity,
}) =>
    ScenarioSimulationResult.fromJson({
      'ticker': 'NVDA',
      'company_name': 'NVIDIA Corporation',
      'generated_at': '2026-08-10T12:00:00Z',
      'baseline': {
        'period_end': '2026-01-31',
        'period_label': 'FY',
        'period': 'ANNUAL',
        'revenue': 130500000000,
        'ebitda': 83400000000,
        'ebitda_margin_pct': 63.9,
        'interest_expense': 250000000,
        'total_debt': 10300000000,
        'implied_interest_rate_pct': 2.43,
        'effective_tax_rate_pct': 15.0,
        'net_income': 70500000000,
        'eps': reportedEps,
        'model_eps': modelEps,
        'shares_outstanding': 24400000000,
        'free_cash_flow': 60900000000,
        'reference_price': 94.67,
        'price_earnings_multiple': 33.4,
      },
      'applied_variables': {
        if (applied.revenueGrowthPct != null)
          'revenue_growth_pct': applied.revenueGrowthPct,
        if (applied.ebitdaMarginPct != null)
          'ebitda_margin_pct': applied.ebitdaMarginPct,
        if (applied.interestRatePct != null)
          'interest_rate_pct': applied.interestRatePct,
        if (applied.inflationPct != null) 'inflation_pct': applied.inflationPct,
        if (applied.customEvent != null) 'custom_event': applied.customEvent,
      },
      'projection': projection ?? _projectionJson(),
      'sensitivity': sensitivity ??
          [
            {
              'case': 'BEAR',
              'label': 'Pesimista (−5 pp de crecimiento)',
              'variables': {'revenue_growth_pct': 20.0},
              'projection': _projectionJson(
                eps: 3.26,
                epsChange: 15.1,
                impliedPrice: 108.94,
                priceChange: 15.1,
              ),
            },
            {
              'case': 'BASE',
              'label': 'Base (lo que pediste)',
              'variables': {'revenue_growth_pct': 25.0},
              'projection': _projectionJson(),
            },
            {
              'case': 'BULL',
              'label': 'Optimista (+5 pp de crecimiento)',
              'variables': {'revenue_growth_pct': 30.0},
              'projection': _projectionJson(
                eps: 3.54,
                epsChange: 24.9,
                impliedPrice: 118.29,
                priceChange: 24.9,
              ),
            },
          ],
      'valuation_basis': valuationBasis,
      'valuation_note': valuationNote,
      'model_assumptions': assumptions,
      'custom_event': customEvent,
      'custom_event_is_qualitative': true,
      'narrative': narrative,
      'narrative_source': narrative == null ? 'NONE' : 'LLM',
      'availability': availability,
      'degradation_reason': reason,
      'narrative_degradation_reason': narrativeReason,
      'served_from_cache': false,
    });

// --- Harness -----------------------------------------------------------------------------------

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required _FakeAiLabRepository repository,
  List<Override> overrides = const [],
  Size size = const Size(1100, 2200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        aiLabRepositoryProvider.overrideWithValue(repository),
        ...overrides,
      ],
      child: MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // --- Parseo ---------------------------------------------------------------------------------

  group('Parseo de los modelos', () {
    test('un entero grande del JSON se convierte a double sin explotar', () {
      final analysis = _analysis();
      // Los ingresos en dólares llegan como `int` y un cast directo a `double` tira.
      expect(analysis.latestIncome!.revenue, 130500000000.0);
    });

    test('una métrica ausente queda en null y no en cero', () {
      final analysis = _analysis(
        income: [_incomeJson(grossMargin: null, eps: null)],
      );

      expect(analysis.latestIncome!.grossMarginPct, isNull);
      expect(analysis.latestIncome!.epsDiluted, isNull);
    });

    test('un enum desconocido degrada ese campo sin tirar la respuesta', () {
      final analysis = _analysis(
        flags: [_flagJson(kind: 'AMBAR', severity: 'MUY_GRAVE')],
      );

      // `red` como fallback del tipo: ante un valor desconocido, la lectura prudente no es "esto es
      // una fortaleza".
      expect(analysis.flags.single.kind, FlagKind.red);
      expect(analysis.flags.single.severity, FlagSeverity.info);
      expect(analysis.flags.single.title, 'Liquidez holgada');
    });

    test('la deuda neta negativa se reconoce como caja neta', () {
      expect(_analysis().latestBalance!.hasNetCash, isTrue);
      expect(
        _analysis(balances: [_balanceJson(netDebt: 5000000000)])
            .latestBalance!
            .hasNetCash,
        isFalse,
      );
    });

    test('la etiqueta del período incluye el año', () {
      // Con cinco filas de "FY" no se distingue una de otra.
      expect(_analysis().latestIncome!.label, 'FY 2026');
    });

    test('el DuPont incompleto no finge estar completo', () {
      final analysis = _analysis(
        dupont: {
          'net_margin_pct': 54.0,
          'asset_turnover': null,
          'equity_multiplier': 1.41,
          'roe_pct': null,
          'criteria_source': 'RULE',
        },
      );

      expect(analysis.dupont.isComplete, isFalse);
      expect(analysis.dupont.dominantDriver, isNull);
    });

    test('el factor dominante se mide por contribución, no por valor crudo', () {
      // Un margen de 0,54 y un apalancamiento de 1,41 no son comparables crudos: la rotación y el
      // apalancamiento se miden contra 1x, que es su valor neutro.
      final marginDriven = _analysis().dupont;
      expect(marginDriven.dominantDriver, DupontDriver.margin);

      final leverageDriven = _analysis(
        dupont: {
          'net_margin_pct': 4.0,
          'asset_turnover': 1.05,
          'equity_multiplier': 5.0,
          'roe_pct': 21.0,
          'criteria_source': 'RULE',
        },
      ).dupont;
      expect(leverageDriven.dominantDriver, DupontDriver.leverage);
    });

    test('el punto cero del modelo se distingue del EPS reportado', () {
      expect(_simulation().baseline.modelEpsDiffers, isTrue);
      expect(
        _simulation(modelEps: 2.87, reportedEps: 2.87).baseline.modelEpsDiffers,
        isFalse,
      );
    });
  });

  // --- Serialización de las variables ---------------------------------------------------------

  group('ScenarioVariables', () {
    test('una palanca sin fijar NO viaja en el cuerpo', () {
      // Mandarla en `null` sería fijarla en null, que el schema del backend rechaza con un 422.
      const variables = ScenarioVariables(revenueGrowthPct: 10);
      final payload = variables.toJson();

      expect(payload, containsPair('revenue_growth_pct', 10.0));
      expect(payload.containsKey('ebitda_margin_pct'), isFalse);
      expect(payload.containsKey('interest_rate_pct'), isFalse);
      expect(payload.containsKey('inflation_pct'), isFalse);
    });

    test('un cero SÍ viaja: no es lo mismo que sin fijar', () {
      const variables = ScenarioVariables(revenueGrowthPct: 0, ebitdaMarginPct: 0);
      final payload = variables.toJson();

      expect(payload, containsPair('revenue_growth_pct', 0.0));
      expect(payload, containsPair('ebitda_margin_pct', 0.0));
    });

    test('un evento vacío no viaja', () {
      expect(
        const ScenarioVariables(customEvent: '   ').toJson().containsKey('custom_event'),
        isFalse,
      );
    });

    test('distingue un escenario con palancas de uno con solo un rumor', () {
      const onlyEvent = ScenarioVariables(customEvent: 'Se cae la fusión.');
      expect(onlyEvent.hasQuantitativeLever, isFalse);
      expect(onlyEvent.hasCustomEvent, isTrue);
      expect(onlyEvent.isEmpty, isFalse);

      expect(const ScenarioVariables().isEmpty, isTrue);
    });

    test('igualdad estructural: dos juegos iguales son el mismo', () {
      expect(
        const ScenarioVariables(revenueGrowthPct: 10, inflationPct: 5),
        const ScenarioVariables(revenueGrowthPct: 10, inflationPct: 5),
      );
      expect(
        const ScenarioVariables(revenueGrowthPct: 10),
        isNot(const ScenarioVariables(revenueGrowthPct: 0)),
      );
    });
  });

  group('ScenarioVariablesController', () {
    test('apagar una palanca la vuelve a "sin fijar"', () {
      final controller = ScenarioVariablesController();
      controller.setMargin(40);
      expect(controller.state.ebitdaMarginPct, 40);

      controller.setMargin(null);
      expect(controller.state.ebitdaMarginPct, isNull);
    });

    test('el margen se activa en el margen REAL de la empresa cuando se conoce', () {
      // Arrancar en el margen del balance hace que el primer movimiento del slider sea una decisión
      // sobre ESE negocio y no sobre un número genérico.
      final controller = ScenarioVariablesController();
      controller.activateMargin(baselineMarginPct: 63.9);
      expect(controller.state.ebitdaMarginPct, 63.9);

      controller.reset();
      controller.activateMargin();
      expect(
        controller.state.ebitdaMarginPct,
        ScenarioVariablesController.defaultMarginPct,
      );
    });

    test('la tasa se activa en la implícita del balance cuando se conoce', () {
      final controller = ScenarioVariablesController();
      controller.activateInterest(impliedRatePct: 2.43);
      expect(controller.state.interestRatePct, 2.43);
    });

    test('un valor fuera de rango se recorta al del schema', () {
      final controller = ScenarioVariablesController();
      controller.activateMargin(baselineMarginPct: 480);
      expect(controller.state.ebitdaMarginPct, 100);
    });
  });

  // --- Controller del diagnóstico -------------------------------------------------------------

  group('AnalysisController', () {
    testWidgets('carga el diagnóstico y expone los bloques', (tester) async {
      final repository = _FakeAiLabRepository();
      final container = ProviderContainer(
        overrides: [aiLabRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      await container.read(analysisControllerProvider.notifier).load('nvda');
      final state = container.read(analysisControllerProvider);

      expect(state.ticker, 'NVDA');
      expect(state.analysis, isNotNull);
      expect(repository.analyzeCalls.single['question'], isNull);
    });

    testWidgets('la pregunta viaja con el historial que devolvió el backend',
        (tester) async {
      final repository = _FakeAiLabRepository();
      final container = ProviderContainer(
        overrides: [aiLabRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      final controller = container.read(analysisControllerProvider.notifier);
      await controller.load('NVDA');
      await controller.ask('¿De dónde viene el ROE?');
      await controller.ask('¿Y la deuda?');

      // El segundo turno manda los dos turnos del primero: el hilo lo administra el backend y el
      // cliente lo reenvía tal cual.
      expect(repository.analyzeCalls[1]['historyLength'], 0);
      expect(repository.analyzeCalls[2]['historyLength'], 2);
    });

    testWidgets('un error en la pregunta no borra el diagnóstico', (tester) async {
      final repository = _FakeAiLabRepository();
      final container = ProviderContainer(
        overrides: [aiLabRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      final controller = container.read(analysisControllerProvider.notifier);
      await controller.load('NVDA');
      repository.analyzeFailure = Exception('sin red');
      await controller.ask('¿Y la deuda?');

      final state = container.read(analysisControllerProvider);
      // Lo que estaba en pantalla sigue siendo válido: borrarlo castigaría al usuario por un error
      // de red.
      expect(state.analysis, isNotNull);
      expect(state.errorMessage, isNotNull);
    });

    testWidgets('reiniciar el hilo conserva los estados contables', (tester) async {
      final repository = _FakeAiLabRepository();
      final container = ProviderContainer(
        overrides: [aiLabRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      final controller = container.read(analysisControllerProvider.notifier);
      await controller.load('NVDA');
      await controller.ask('¿De dónde viene el ROE?');
      controller.clearConversation();

      final state = container.read(analysisControllerProvider);
      expect(state.history, isEmpty);
      expect(state.analysis!.dupont.isComplete, isTrue);
    });

    testWidgets('no se recarga el mismo símbolo dos veces sin force',
        (tester) async {
      final repository = _FakeAiLabRepository();
      final container = ProviderContainer(
        overrides: [aiLabRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      final controller = container.read(analysisControllerProvider.notifier);
      await controller.load('NVDA');
      await controller.load('NVDA');
      expect(repository.analyzeCalls.length, 1);

      await controller.load('NVDA', force: true);
      expect(repository.analyzeCalls.length, 2);
    });
  });

  // --- Controller de la simulación ------------------------------------------------------------

  group('SimulationController', () {
    testWidgets('manda solo las palancas fijadas', (tester) async {
      final repository = _FakeAiLabRepository();
      final container = ProviderContainer(
        overrides: [aiLabRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      container.read(aiLabTickerProvider.notifier).state = 'NVDA';
      container.read(scenarioVariablesProvider.notifier).setGrowth(25);
      await container.read(simulationControllerProvider.notifier).run();

      final payload = repository.simulateCalls.single['payload']!
          as Map<String, dynamic>;
      expect(payload.keys, ['revenue_growth_pct']);
    });

    testWidgets('sin símbolo elegido no se llama al backend', (tester) async {
      final repository = _FakeAiLabRepository();
      final container = ProviderContainer(
        overrides: [aiLabRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      await container.read(simulationControllerProvider.notifier).run();
      expect(repository.simulateCalls, isEmpty);
    });

    testWidgets('avisa cuando el resultado quedó viejo respecto de las palancas',
        (tester) async {
      final repository = _FakeAiLabRepository();
      final container = ProviderContainer(
        overrides: [aiLabRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      container.read(aiLabTickerProvider.notifier).state = 'NVDA';
      container.read(scenarioVariablesProvider.notifier).setGrowth(25);
      await container.read(simulationControllerProvider.notifier).run();

      final state = container.read(simulationControllerProvider);
      expect(state.isStale(container.read(scenarioVariablesProvider)), isFalse);

      container.read(scenarioVariablesProvider.notifier).setGrowth(30);
      // Mover un slider y leer el resultado viejo es el error más fácil de cometer en esta pantalla.
      expect(state.isStale(container.read(scenarioVariablesProvider)), isTrue);
    });

    testWidgets('un fallo conserva el resultado anterior con su error',
        (tester) async {
      final repository = _FakeAiLabRepository();
      final container = ProviderContainer(
        overrides: [aiLabRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      container.read(aiLabTickerProvider.notifier).state = 'NVDA';
      await container.read(simulationControllerProvider.notifier).run();
      repository.simulateFailure = Exception('sin red');
      await container.read(simulationControllerProvider.notifier).run();

      final state = container.read(simulationControllerProvider);
      expect(state.result, isNotNull);
      expect(state.errorMessage, isNotNull);
    });
  });

  // --- Pestaña de análisis --------------------------------------------------------------------

  group('Pestaña Análisis contable', () {
    testWidgets('sin símbolo invita a elegir una empresa', (tester) async {
      await _pump(
        tester,
        const FinancialAnalysisTab(),
        repository: _FakeAiLabRepository(),
      );

      expect(find.textContaining('Elegí una empresa arriba'), findsOneWidget);
    });

    testWidgets('muestra márgenes, balance, caja, DuPont y banderas',
        (tester) async {
      final repository = _FakeAiLabRepository();
      await _pump(
        tester,
        const FinancialAnalysisTab(),
        repository: repository,
      );
      // El diagnóstico se dispara desde el controller, como lo hace la pantalla real.
      final element = tester.element(find.byType(FinancialAnalysisTab));
      await ProviderScope.containerOf(element)
          .read(analysisControllerProvider.notifier)
          .load('NVDA');
      await tester.pumpAndSettle();

      expect(find.text('Márgenes'), findsOneWidget);
      expect(find.text('Balance'), findsOneWidget);
      expect(find.text('Caja'), findsOneWidget);
      expect(find.text('DuPont — de dónde viene el ROE'), findsOneWidget);
      expect(find.text('Banderas'), findsOneWidget);
      expect(find.text('Liquidez holgada'), findsOneWidget);
    });

    testWidgets('el DuPont dice cuál factor pesa más', (tester) async {
      await _pumpLoaded(tester, _FakeAiLabRepository());

      // El valor del bloque no son los tres números: es esta lectura.
      expect(
        find.text('El factor que más pesa es el margen.'),
        findsOneWidget,
      );
    });

    testWidgets('un DuPont incompleto lo dice sin estimar', (tester) async {
      await _pumpLoaded(
        tester,
        _FakeAiLabRepository(
          analysis: _analysis(
            dupont: {
              'net_margin_pct': 54.0,
              'asset_turnover': null,
              'equity_multiplier': null,
              'roe_pct': null,
              'criteria_source': 'RULE',
            },
          ),
        ),
      );

      expect(
        find.textContaining('No se pudo descomponer el ROE'),
        findsOneWidget,
      );
    });

    testWidgets('una métrica ausente se muestra con guion y no con cero',
        (tester) async {
      await _pumpLoaded(
        tester,
        _FakeAiLabRepository(
          analysis: _analysis(income: [_incomeJson(grossMargin: null)]),
        ),
      );

      expect(find.text('—'), findsWidgets);
      expect(find.text('0,0%'), findsNothing);
    });

    testWidgets('un EBITDA reconstruido se declara', (tester) async {
      await _pumpLoaded(tester, _FakeAiLabRepository());

      // Presentar un EBITDA reconstruido como el que informa la empresa le atribuiría una cifra que
      // no dijo.
      expect(
        find.text('EBITDA reconstruido: operativo + amortizaciones'),
        findsOneWidget,
      );
    });

    testWidgets('las banderas declaran que son reglas con umbral', (tester) async {
      await _pumpLoaded(tester, _FakeAiLabRepository());

      expect(
        find.textContaining('umbrales fijos, no por un modelo'),
        findsOneWidget,
      );
      // El detalle trae el valor y el umbral, redactados por el backend.
      expect(
        find.text('Liquidez corriente de 3,67x, por encima de 2,00x.'),
        findsOneWidget,
      );
    });

    testWidgets('sin banderas se aclara que no es un veredicto positivo',
        (tester) async {
      await _pumpLoaded(
        tester,
        _FakeAiLabRepository(analysis: _analysis(flags: const [])),
      );

      expect(
        find.textContaining('No es un veredicto positivo'),
        findsOneWidget,
      );
    });

    testWidgets('la lectura del modelo lleva su marca de origen', (tester) async {
      await _pumpLoaded(tester, _FakeAiLabRepository());

      expect(find.text('El ROE viene del margen y de la rotación.'), findsOneWidget);
      // Sin esta marca, un párrafo bien escrito arriba de una tabla se lee con la misma autoridad
      // que la tabla.
      expect(
        find.textContaining('Texto redactado por IA sobre los números calculados'),
        findsOneWidget,
      );
    });

    testWidgets('sin narrativa se muestra el motivo y los números quedan',
        (tester) async {
      await _pumpLoaded(
        tester,
        _FakeAiLabRepository(
          analysis: _analysis(
            narrative: null,
            narrativeSource: 'NONE',
            narrativeReason: 'La lectura escrita por IA no está disponible.',
          ),
        ),
      );

      expect(find.byType(DegradationBanner), findsOneWidget);
      expect(
        find.text('La lectura escrita por IA no está disponible.'),
        findsOneWidget,
      );
      // Los números siguen ahí: es toda la diferencia entre "falta la prosa" y "falta el análisis".
      expect(find.text('Márgenes'), findsOneWidget);
      expect(find.text('DuPont — de dónde viene el ROE'), findsOneWidget);
    });

    testWidgets('sin estados contables se avisa y no se ofrece el chat',
        (tester) async {
      await _pumpLoaded(
        tester,
        _FakeAiLabRepository(
          analysis: _analysis(
            income: const [],
            balances: const [],
            cashFlows: const [],
            narrative: null,
            narrativeSource: 'NONE',
            availability: 'UNAVAILABLE',
            reason: 'El proveedor no publica estados de este símbolo.',
          ),
        ),
      );

      expect(
        find.text('El proveedor no publica estados de este símbolo.'),
        findsOneWidget,
      );
      // Sin estados no hay sobre qué preguntar: el modelo escribiría sobre un conjunto vacío.
      expect(find.byType(AnalysisChat), findsNothing);
    });

    testWidgets('la evolución aparece cuando hay más de un período',
        (tester) async {
      await _pumpLoaded(
        tester,
        _FakeAiLabRepository(
          analysis: _analysis(
            income: [
              _incomeJson(),
              _incomeJson(date: '2025-01-31', revenue: 60900000000),
            ],
          ),
        ),
      );

      expect(find.text('Evolución'), findsOneWidget);
    });
  });

  // --- Chat -----------------------------------------------------------------------------------

  group('Chat del análisis', () {
    testWidgets('las sugerencias mandan la pregunta', (tester) async {
      final repository = _FakeAiLabRepository();
      await _pumpLoaded(tester, repository);

      await tester.tap(find.text(AnalysisChat.suggestions.first));
      await tester.pumpAndSettle();

      expect(repository.analyzeCalls.last['question'],
          AnalysisChat.suggestions.first);
    });

    testWidgets('el hilo muestra los dos lados de la conversación',
        (tester) async {
      await _pumpLoaded(
        tester,
        _FakeAiLabRepository(
          analysis: _analysis(
            history: const [
              // A propósito NO es una de las sugerencias: esas siguen ofrecidas abajo del hilo, así
              // que un texto compartido encontraría dos widgets y el test no distinguiría la burbuja
              // del chip.
              ConversationTurn(
                role: ConversationRole.user,
                content: '¿Cuánto pesa el capital de trabajo?',
              ),
              ConversationTurn(
                role: ConversationRole.assistant,
                content: 'Del margen.',
              ),
            ],
          ),
        ),
      );

      expect(find.text('Vos'), findsOneWidget);
      expect(find.text('Analista contable'), findsOneWidget);
      expect(find.text('¿Cuánto pesa el capital de trabajo?'), findsOneWidget);
      expect(find.text('Del margen.'), findsOneWidget);
    });

    testWidgets('el hilo vacío explica sobre qué se apoyan las respuestas',
        (tester) async {
      await _pumpLoaded(tester, _FakeAiLabRepository());

      expect(
        find.textContaining('si un dato no está ahí, el analista lo va a decir'),
        findsOneWidget,
      );
    });
  });

  // --- Pestaña del simulador ------------------------------------------------------------------

  group('Pestaña Simulador', () {
    testWidgets('sin símbolo invita a elegir una empresa', (tester) async {
      await _pump(
        tester,
        const ScenarioSimulatorTab(),
        repository: _FakeAiLabRepository(),
      );

      expect(find.textContaining('Elegí una empresa arriba'), findsOneWidget);
    });

    testWidgets('las cuatro palancas arrancan sin fijar', (tester) async {
      await _pumpSimulator(tester, _FakeAiLabRepository());

      expect(find.byType(ScenarioLever), findsNWidgets(4));
      // "Sin fijar" en las cuatro: un slider que arranca en un número ya sería un supuesto que el
      // usuario no eligió.
      expect(find.text('sin fijar'), findsNWidgets(4));
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('cada palanca explica qué pasa si queda apagada', (tester) async {
      await _pumpSimulator(tester, _FakeAiLabRepository());

      expect(
        find.textContaining('se parte del margen del balance y la inflación'),
        findsOneWidget,
      );
      expect(
        find.textContaining('el gasto de intereses queda igual'),
        findsOneWidget,
      );
    });

    testWidgets('encender una palanca muestra su slider con un valor',
        (tester) async {
      await _pumpSimulator(tester, _FakeAiLabRepository());

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('sin fijar'), findsNWidgets(3));
      // El crecimiento es una VARIACIÓN: el signo es parte del dato.
      expect(find.text('+10,0%'), findsOneWidget);
    });

    testWidgets('un nivel no se muestra con signo de variación', (tester) async {
      // Un margen EBITDA de 30% mostrado como "+30,0%" se leería como "30 puntos MÁS de margen",
      // que es otro escenario. El crecimiento, en cambio, SÍ lleva signo.
      await _pumpSimulator(tester, _FakeAiLabRepository());

      await tester.tap(find.byType(Switch).at(1));
      await tester.pumpAndSettle();

      expect(find.text('30,0%'), findsOneWidget);
      expect(find.text('+30,0%'), findsNothing);
    });

    testWidgets('el aviso del evento va antes de escribirlo', (tester) async {
      await _pumpSimulator(tester, _FakeAiLabRepository());

      // Alguien que escribe "pierden el juicio" tiene que saber ANTES que el EPS proyectado no lo
      // incluye.
      expect(
        find.textContaining('El evento NO se cuantifica'),
        findsOneWidget,
      );
    });

    testWidgets('ejecutar la simulación muestra la variación y la matriz',
        (tester) async {
      final repository = _FakeAiLabRepository();
      await _pumpSimulator(tester, repository);

      await tester.tap(find.text('Ejecutar simulación'));
      await tester.pumpAndSettle();

      expect(find.text('Variación estimada en la cotización'), findsOneWidget);
      expect(find.text('+20,0%'), findsWidgets);
      expect(find.byType(SensitivityMatrix), findsOneWidget);
      expect(find.text('PESIMISTA'), findsOneWidget);
      expect(find.text('OPTIMISTA'), findsOneWidget);
    });

    testWidgets('el precio implícito aclara que no es un precio objetivo',
        (tester) async {
      final repository = _FakeAiLabRepository();
      await _pumpSimulator(tester, repository);
      await tester.tap(find.text('Ejecutar simulación'));
      await tester.pumpAndSettle();

      // Confundir una medida de sensibilidad con un precio objetivo es el error más caro que se
      // puede cometer con esta pantalla.
      expect(find.textContaining('NO es un precio objetivo'), findsOneWidget);
    });

    testWidgets('sin precio implícito se muestra el motivo del backend',
        (tester) async {
      final repository = _FakeAiLabRepository(
        simulation: _simulation(
          projection: _projectionJson(impliedPrice: null, priceChange: null),
          valuationBasis: 'NOT_APPLICABLE',
          valuationNote:
              'El EPS del período base no es positivo: un múltiplo no tiene interpretación.',
        ),
      );
      await _pumpSimulator(tester, repository);
      await tester.tap(find.text('Ejecutar simulación'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('El EPS del período base no es positivo'),
        findsOneWidget,
      );
    });

    testWidgets('los supuestos del modelo se muestran enteros', (tester) async {
      final repository = _FakeAiLabRepository();
      await _pumpSimulator(tester, repository);
      await tester.tap(find.text('Ejecutar simulación'));
      await tester.pumpAndSettle();

      expect(find.text('Supuestos del modelo'), findsOneWidget);
      expect(
        find.textContaining('El crecimiento de ingresos que ingresás se toma como NOMINAL'),
        findsOneWidget,
      );
    });

    testWidgets('el evento vuelve con su aclaración de que no movió números',
        (tester) async {
      final repository = _FakeAiLabRepository(
        simulation: _simulation(customEvent: 'Un tribunal frena las exportaciones.'),
      );
      await _pumpSimulator(tester, repository);
      await tester.tap(find.text('Ejecutar simulación'));
      await tester.pumpAndSettle();

      expect(find.text('Un tribunal frena las exportaciones.'), findsOneWidget);
      expect(
        find.textContaining('ninguno de los números de arriba lo incluye'),
        findsOneWidget,
      );
    });

    testWidgets('la proyección explica los dos EPS cuando difieren',
        (tester) async {
      final repository = _FakeAiLabRepository();
      await _pumpSimulator(tester, repository);
      await tester.tap(find.text('Ejecutar simulación'));
      await tester.pumpAndSettle();

      // Sin esta línea, la variación parece medida contra el número que la empresa publicó.
      expect(
        find.textContaining('no es el reportado'),
        findsOneWidget,
      );
    });

    testWidgets('un escenario degradado muestra el motivo y no una proyección vacía',
        (tester) async {
      final repository = _FakeAiLabRepository(
        simulation: _simulation(
          availability: 'UNAVAILABLE',
          reason: 'El proveedor de estados contables no está configurado.',
        ),
      );
      await _pumpSimulator(tester, repository);
      await tester.tap(find.text('Ejecutar simulación'));
      await tester.pumpAndSettle();

      expect(
        find.text('El proveedor de estados contables no está configurado.'),
        findsOneWidget,
      );
      expect(find.byType(SensitivityMatrix), findsNothing);
    });

    testWidgets('con solo un rumor se avisa que la proyección no se va a mover',
        (tester) async {
      await _pumpSimulator(tester, _FakeAiLabRepository());

      await tester.enterText(
        find.byType(TextField).first,
        'Se rumorea una adquisición.',
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('la proyección va a ser igual a la base'),
        findsOneWidget,
      );
    });
  });

  // --- Matriz ---------------------------------------------------------------------------------

  group('SensitivityMatrix', () {
    testWidgets('lee el ancho del rango, no solo los tres números',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: SensitivityMatrix(cases: _simulation().sensitivity),
          ),
        ),
      );

      // 24,9 − 15,1 ≈ 9,8 pp de diferencia: poco sensible según los umbrales del producto.
      expect(
        find.textContaining('de diferencia en el EPS'),
        findsOneWidget,
      );
      expect(
        find.textContaining('poco sensible a los supuestos'),
        findsOneWidget,
      );
    });

    testWidgets('un rango ancho se lee como muy sensible', (tester) async {
      final wide = _simulation(
        sensitivity: [
          {
            'case': 'BEAR',
            'label': 'Pesimista',
            'variables': const <String, dynamic>{},
            'projection': _projectionJson(eps: 1.0, epsChange: -40.0),
          },
          {
            'case': 'BASE',
            'label': 'Base',
            'variables': const <String, dynamic>{},
            'projection': _projectionJson(),
          },
          {
            'case': 'BULL',
            'label': 'Optimista',
            'variables': const <String, dynamic>{},
            'projection': _projectionJson(eps: 5.0, epsChange: 60.0),
          },
        ],
      ).sensitivity;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(body: SensitivityMatrix(cases: wide)),
        ),
      );

      expect(
        find.textContaining('muy sensible a los supuestos'),
        findsOneWidget,
      );
    });

    testWidgets('el color sale del signo de la variación, no del nombre del caso',
        (tester) async {
      // Un "bear" que igual da +15% no es una mala noticia, y un "bull" que da −8% no es una buena:
      // pintarlos por el nombre del caso afirmaría lo contrario de lo que dice el número. Por eso el
      // escenario de este test tiene los signos cruzados a propósito.
      final crossed = _simulation(
        sensitivity: [
          {
            'case': 'BEAR',
            'label': 'Pesimista',
            'variables': const <String, dynamic>{},
            'projection': _projectionJson(eps: 3.26, epsChange: 15.1),
          },
          {
            'case': 'BASE',
            'label': 'Base',
            'variables': const <String, dynamic>{},
            'projection': _projectionJson(epsChange: 0.0),
          },
          {
            'case': 'BULL',
            'label': 'Optimista',
            'variables': const <String, dynamic>{},
            'projection': _projectionJson(eps: 2.60, epsChange: -8.0),
          },
        ],
      ).sensitivity;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(body: SensitivityMatrix(cases: crossed)),
        ),
      );

      Color? colorOf(String text) =>
          tester.widget<Text>(find.text(text)).style?.color;

      // El pesimista que sube va en verde; el optimista que baja, en rojo.
      expect(colorOf('+15,1%'), AppTheme.bullish);
      expect(colorOf('−8,0%'), AppTheme.bearish);
      // Un cero exacto no es ni una cosa ni la otra: se pinta neutro.
      expect(colorOf('0,0%'), AppTheme.accent);
      // Y el EPS de cada tarjeta acompaña el color de su propia variación.
      expect(colorOf('3,26'), AppTheme.bullish);
      expect(colorOf('2,60'), AppTheme.bearish);
    });
  });

  // --- Bloques del Lab ------------------------------------------------------------------------

  group('Bloques para el Investment Lab', () {
    test('el diagnóstico transcribe márgenes, DuPont y banderas', () {
      final markdown = buildAnalysisNoteMarkdown(
        _analysis(),
        now: DateTime(2026, 8, 10, 15, 30),
      );

      expect(markdown, contains('## $kAnalysisSnippetHeading — NVDA'));
      expect(
        markdown,
        contains('Guardado desde el Laboratorio Financiero el 10/08/2026 15:30'),
      );
      expect(markdown, contains('Margen neto'));
      expect(markdown, contains('### DuPont'));
      expect(markdown, contains('El factor que más pesa es **el margen**'));
      expect(markdown, contains('Liquidez holgada'));
    });

    test('la nota copia la advertencia de origen de la prosa', () {
      final markdown = buildAnalysisNoteMarkdown(_analysis());

      // La nota es lo que se relee: sin la marca, el párrafo se lee como una conclusión propia.
      expect(markdown, contains('Lectura redactada por IA'));
      expect(markdown, contains('no una recomendación de inversión'));
    });

    test('sin estados la nota deja constancia en vez de quedar vacía', () {
      final markdown = buildAnalysisNoteMarkdown(
        _analysis(
          income: const [],
          balances: const [],
          cashFlows: const [],
          availability: 'UNAVAILABLE',
          reason: 'El proveedor no publica estados de este símbolo.',
        ),
      );

      expect(markdown, contains('Sin estados contables'));
      expect(markdown, contains('El proveedor no publica estados'));
    });

    test('la simulación copia supuestos, matriz y la aclaración del evento', () {
      final markdown = buildScenarioNoteMarkdown(
        _simulation(customEvent: 'Se cae la fusión.'),
        now: DateTime(2026, 8, 10, 15, 30),
      );

      expect(markdown, contains('## $kScenarioSnippetHeading — NVDA'));
      expect(markdown, contains('### Supuestos del modelo'));
      expect(markdown, contains('### Matriz de sensibilidad'));
      expect(markdown, contains('Se cae la fusión.'));
      expect(markdown, contains('no está cuantificado'));
    });

    test('la simulación explica contra qué EPS se midió', () {
      final markdown = buildScenarioNoteMarkdown(_simulation());

      expect(markdown, contains('EPS del punto cero del modelo'));
      expect(markdown, contains('las variaciones se miden contra este'));
    });

    test('una palanca sin fijar se escribe como tal y no como cero', () {
      final markdown = buildScenarioNoteMarkdown(
        _simulation(applied: const ScenarioVariables(revenueGrowthPct: 25)),
      );

      expect(markdown, contains('Margen EBITDA: _sin fijar_'));
      expect(markdown, contains('Tasa de interés: _sin fijar_'));
    });

    test('la nota distingue un nivel de una variación', () {
      // La nota se relee semanas después sin la pantalla al lado: un margen escrito "+63,9%" ahí se
      // lee como "63,9 puntos MÁS de margen", que es otro escenario.
      final markdown = buildScenarioNoteMarkdown(
        _simulation(
          applied: const ScenarioVariables(
            revenueGrowthPct: 25,
            ebitdaMarginPct: 52,
            interestRatePct: 8,
          ),
        ),
      );

      expect(markdown, contains('Crecimiento de ingresos: `+25,0%`'));
      expect(markdown, contains('Margen EBITDA: `52,0%`'));
      expect(markdown, contains('Tasa de interés: `8,0%`'));
      // El punto de partida también: el margen del balance es un nivel.
      expect(markdown, contains('margen `63,9%`'));
      // Y las variaciones de la proyección sí conservan el signo.
      expect(markdown, contains('`+20,0%`'));
    });

    test('el diagnóstico escribe los márgenes sin signo de variación', () {
      final markdown = buildAnalysisNoteMarkdown(_analysis());

      expect(markdown, contains('Margen bruto: `75,0%`'));
      expect(markdown, contains('ROE 88,9%'));
      expect(markdown, isNot(contains('Margen bruto: `+75,0%`')));
    });

    test('el título del escenario describe la palanca que se movió', () {
      // Dos simulaciones del mismo activo se distinguen por lo que se movió, no por cuándo se
      // guardaron.
      final draft = scenarioNoteDraft(_simulation());
      expect(draft.title, contains('crecimiento'));

      final onlyEvent = scenarioNoteDraft(
        _simulation(applied: const ScenarioVariables(customEvent: 'Rumor')),
      );
      expect(onlyEvent.title, contains('solo evento'));
    });

    test('el hilo de la conversación se guarda con los dos lados', () {
      final markdown = buildConversationNoteMarkdown(
        _analysis(
          history: const [
            ConversationTurn(
              role: ConversationRole.user,
              content: '¿De dónde viene el ROE?',
            ),
            ConversationTurn(
              role: ConversationRole.assistant,
              content: 'Del margen.',
            ),
          ],
        ),
      );

      expect(markdown, contains('**Pregunta:** ¿De dónde viene el ROE?'));
      expect(markdown, contains('Del margen.'));
      expect(markdown, contains('Lectura redactada por IA'));
    });

    test('los borradores quedan vinculados al símbolo', () {
      expect(analysisNoteDraft(_analysis()).normalizedTicker, 'NVDA');
      expect(scenarioNoteDraft(_simulation()).normalizedTicker, 'NVDA');
    });
  });

  // --- Semántica del color --------------------------------------------------------------------

  group('Semántica del color', () {
    test('verde y rojo solo para el signo de una bandera', () {
      expect(flagColor(FlagKind.red), AppTheme.bearish);
      expect(flagColor(FlagKind.green), AppTheme.bullish);
    });

    test('el ícono distingue riesgo de fortaleza sin depender del color', () {
      expect(
        flagIcon(FlagKind.green, FlagSeverity.info),
        Icons.check_circle_outline,
      );
      expect(
        flagIcon(FlagKind.red, FlagSeverity.critical),
        Icons.error_outline,
      );
      expect(
        flagIcon(FlagKind.red, FlagSeverity.warning),
        Icons.warning_amber_outlined,
      );
    });
  });
}

// --- Helpers de pump ---------------------------------------------------------------------------

/// Monta la pestaña de análisis con el diagnóstico ya cargado.
Future<void> _pumpLoaded(
  WidgetTester tester,
  _FakeAiLabRepository repository,
) async {
  await _pump(tester, const FinancialAnalysisTab(), repository: repository);
  final element = tester.element(find.byType(FinancialAnalysisTab));
  await ProviderScope.containerOf(element)
      .read(analysisControllerProvider.notifier)
      .load('NVDA');
  await tester.pumpAndSettle();
}

/// Monta el simulador con el símbolo ya elegido.
Future<void> _pumpSimulator(
  WidgetTester tester,
  _FakeAiLabRepository repository,
) async {
  await _pump(
    tester,
    const ScenarioSimulatorTab(),
    repository: repository,
    overrides: [
      aiLabTickerProvider.overrideWith((ref) => 'NVDA'),
    ],
  );
}
