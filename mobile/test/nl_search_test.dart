import 'package:dio/dio.dart';
import 'package:financiero_app/core/providers.dart';
import 'package:financiero_app/core/theme/app_theme.dart';
import 'package:financiero_app/features/settings/data/exchange_type.dart';
import 'package:financiero_app/features/tickers/data/nl_search_result.dart';
import 'package:financiero_app/features/tickers/data/search_nl_repository.dart';
import 'package:financiero_app/features/tickers/presentation/nl_search_controller.dart';
import 'package:financiero_app/features/tickers/widgets/nl_search_results.dart';
import 'package:financiero_app/features/watchlist/data/portfolio_audit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests de la búsqueda conversacional.
///
/// Los contratos que esta pantalla promete y que son fáciles de romper sin darse cuenta:
///
///   1. **La interpretación se muestra siempre.** Es el modo de falla propio de una búsqueda en
///      lenguaje natural: si el modelo entendió otra cosa, los resultados son correctos y a la vez
///      inútiles, y sin verla el usuario no tiene forma de darse cuenta.
///   2. **Los criterios no aplicados se listan uno por uno.** Su ausencia cambia el significado de
///      la lista: sin el filtro de P/E, esos resultados NO cumplen lo que se pidió.
///   3. **La razón de coincidencia se muestra tal cual la manda el backend**, que la compone con los
///      valores medidos — la UI no la reescribe ni la resume.
///   4. **No se busca al tipear.** Cada consulta gasta una llamada al modelo.

class _FakeSearchRepository implements SearchNlRepository {
  _FakeSearchRepository({this.result, this.error});

  final NlSearchResult? result;
  final Object? error;

  final List<String> queries = [];

  @override
  Future<NlSearchResult> search(
    String query, {
    int limit = 20,
    CancelToken? cancelToken,
  }) async {
    queries.add(query);
    if (error != null) throw error!;
    return result!;
  }
}

NlSearchResult _result({
  String query = 'tecnológicas baratas',
  String? interpretation = 'Buscás tecnológicas con múltiplo bajo.',
  SearchCriteria criteria = SearchCriteria.empty,
  CriteriaSource source = CriteriaSource.ai,
  List<NlTickerMatch> results = const [],
  int candidatesEvaluated = 0,
  bool aiAvailable = true,
  bool metricsAvailable = true,
  List<String> unapplied = const [],
  String? degradationReason,
}) =>
    NlSearchResult(
      query: query,
      interpretation: interpretation,
      criteria: criteria,
      criteriaSource: source,
      results: results,
      candidatesEvaluated: candidatesEvaluated,
      aiAvailable: aiAvailable,
      metricsAvailable: metricsAvailable,
      unappliedCriteria: unapplied,
      degradationReason: degradationReason,
    );

NlTickerMatch _match({
  String symbol = 'AAPL',
  String name = 'Apple Inc.',
  ExchangeType? exchange = ExchangeType.nasdaq,
  PortfolioSector sector = PortfolioSector.tecnologia,
  String matchReason = 'Sector Tecnología, P/E de 12.00x',
  double? priceEarnings = 12.0,
  double? debtToEquity,
}) =>
    NlTickerMatch(
      symbol: symbol,
      name: name,
      exchange: exchange,
      sector: sector,
      sectorLabel: 'Tecnología',
      matchReason: matchReason,
      priceEarnings: priceEarnings,
      debtToEquity: debtToEquity,
      returnOnEquityPct: null,
      revenueGrowthYoyPct: null,
      marketCapUsd: null,
    );

/// Monta la vista de resultados sobre un estado dado. Se prueba el widget de resultados y no la
/// hoja entera: la hoja aporta el campo de texto y el modal, y lo que importa acá es cómo se
/// presenta cada estado de la respuesta.
Future<void> _pumpResults(WidgetTester tester, NlSearchState state) async {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: NlSearchResultsView(
            state: state,
            onOpenTicker: (_) {},
            onExampleTapped: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // --- Parseo del contrato -----------------------------------------------------------------

  group('NlSearchResult.fromJson', () {
    test('lee la respuesta completa del backend', () {
      final result = NlSearchResult.fromJson(const {
        'query': 'tecnológicas baratas',
        'interpretation': 'Buscás tecnológicas con múltiplo bajo.',
        'criteria': {
          'sectors': ['TECNOLOGIA'],
          'exchanges': ['NASDAQ'],
          'price_earnings': {'minimum': null, 'maximum': 15.0},
          'debt_to_equity': {'minimum': null, 'maximum': 0.5},
          'return_on_equity_pct': {'minimum': null, 'maximum': null},
          'revenue_growth_yoy_pct': {'minimum': null, 'maximum': null},
          'market_cap_usd': {'minimum': null, 'maximum': null},
          'free_cash_flow_positive': true,
          'text_query': null,
        },
        'criteria_source': 'AI',
        'results': [
          {
            'symbol': 'AAPL',
            'name': 'Apple Inc.',
            'exchange': 'NASDAQ',
            'sector': 'TECNOLOGIA',
            'sector_label': 'Tecnología',
            'match_reason': 'Sector Tecnología, P/E de 12.00x',
            'price_earnings': 12.0,
            'debt_to_equity': 0.3,
            'return_on_equity_pct': null,
            'revenue_growth_yoy_pct': null,
            'market_cap_usd': 3000000000000.0,
          },
        ],
        'candidates_evaluated': 40,
        'ai_available': true,
        'metrics_available': true,
        'unapplied_criteria': [],
        'degradation_reason': null,
      });

      expect(result.wasInterpreted, isTrue);
      expect(result.criteria.sectors, [PortfolioSector.tecnologia]);
      expect(result.criteria.exchanges, [ExchangeType.nasdaq]);
      expect(result.criteria.freeCashFlowPositive, isTrue);
      expect(result.candidatesEvaluated, 40);
      final match = result.results.single;
      expect(match.symbol, 'AAPL');
      expect(match.matchReason, 'Sector Tecnología, P/E de 12.00x');
      expect(match.priceEarnings, 12.0);
    });

    test('una fuente de criterios desconocida se degrada a búsqueda por texto',
        () {
      // `textFallback` es la afirmación más débil: un valor inesperado no puede terminar
      // presentando una búsqueda por coincidencia como si la hubiera interpretado el modelo.
      expect(criteriaSourceFromWire('MAGIA'), CriteriaSource.textFallback);
      expect(criteriaSourceFromWire(null), CriteriaSource.textFallback);
      expect(criteriaSourceFromWire('AI'), CriteriaSource.ai);
    });

    test('los criterios ausentes no se inventan', () {
      final criteria = SearchCriteria.fromJson(const {});

      expect(criteria.sectors, isEmpty);
      expect(criteria.priceEarnings.isEmpty, isTrue);
      expect(criteria.freeCashFlowPositive, isNull);
      expect(criteria.numericLabels, isEmpty);
    });

    test('un rango con un solo extremo se describe sin inventar el otro', () {
      // Mostrar un mínimo inventado (0) afirmaría un filtro que el usuario no pidió.
      expect(
        const NumericRange(minimum: null, maximum: 15).describe('P/E'),
        'P/E < 15',
      );
      expect(
        const NumericRange(minimum: 20, maximum: null).describe('ROE'),
        'ROE > 20',
      );
      expect(
        const NumericRange(minimum: 10, maximum: 20).describe('P/E'),
        'P/E 10–20',
      );
    });

    test('solo se muestran los ratios que se midieron', () {
      // Un hueco no se rellena con 0: un P/E de 0 y un P/E desconocido significan cosas muy
      // distintas.
      final chips = _match(priceEarnings: 12.0, debtToEquity: null).ratioChips;

      expect(chips.map((chip) => chip.$1), ['P/E']);
    });
  });

  // --- La vista de resultados ---------------------------------------------------------------

  testWidgets('muestra la interpretación del agente y sus criterios', (
    tester,
  ) async {
    await _pumpResults(
      tester,
      NlSearchState(
        result: _result(
          interpretation: 'Buscás tecnológicas con múltiplo bajo y poca deuda.',
          criteria: const SearchCriteria(
            sectors: [PortfolioSector.tecnologia],
            exchanges: [ExchangeType.nasdaq],
            priceEarnings: NumericRange(minimum: null, maximum: 15),
            debtToEquity: NumericRange(minimum: null, maximum: 0.5),
            returnOnEquityPct: NumericRange.empty,
            revenueGrowthYoyPct: NumericRange.empty,
            marketCapUsd: NumericRange.empty,
            freeCashFlowPositive: null,
            textQuery: null,
          ),
          results: [_match()],
          candidatesEvaluated: 3,
        ),
        isLoading: false,
      ),
    );

    expect(find.text('ASÍ ENTENDÍ TU BÚSQUEDA'), findsOneWidget);
    expect(
      find.text('Buscás tecnológicas con múltiplo bajo y poca deuda.'),
      findsOneWidget,
    );
    // Los criterios como chips: leer "P/E < 15" y darse cuenta de que uno no pidió eso es más
    // rápido que deducirlo de una lista de resultados inesperados.
    expect(find.text('Tecnología'), findsWidgets);
    expect(find.text('P/E < 15'), findsOneWidget);
    expect(find.text('Deuda/Equity < 0.5'), findsOneWidget);
  });

  testWidgets('muestra la razón de coincidencia de cada resultado', (
    tester,
  ) async {
    await _pumpResults(
      tester,
      NlSearchState(
        result: _result(
          results: [
            _match(
              symbol: 'AAPL',
              matchReason: 'Sector Tecnología, P/E de 12.00x, '
                  'Deuda/Equity de 0.30x',
              debtToEquity: 0.3,
            ),
          ],
          candidatesEvaluated: 3,
        ),
        isLoading: false,
      ),
    );

    // La razón se muestra tal cual: la compone el backend con los valores medidos, así que
    // reescribirla acá le sacaría la trazabilidad que la hace verificable.
    expect(
      find.text('Sector Tecnología, P/E de 12.00x, Deuda/Equity de 0.30x'),
      findsOneWidget,
    );
    expect(find.text('AAPL'), findsOneWidget);
    expect(find.text('12.00x'), findsOneWidget);
    expect(find.text('0.30x'), findsOneWidget);
  });

  testWidgets('lista los criterios que no se pudieron aplicar', (tester) async {
    await _pumpResults(
      tester,
      NlSearchState(
        result: _result(
          metricsAvailable: false,
          results: [_match(priceEarnings: null)],
          candidatesEvaluated: 3,
          unapplied: const ['P/E menor a 15', 'Flujo de caja libre positivo'],
          degradationReason:
              'Los ratios no están configurados en este entorno.',
        ),
        isLoading: false,
      ),
    );

    expect(find.text('2 filtros no se pudieron aplicar'), findsOneWidget);
    expect(find.text('· P/E menor a 15'), findsOneWidget);
    expect(find.text('· Flujo de caja libre positivo'), findsOneWidget);
    // La advertencia explícita: sin ella, la lista se leería como si cumpliera todo lo pedido.
    expect(
      find.textContaining('NO cumplen necesariamente'),
      findsOneWidget,
    );
  });

  testWidgets('sin interpretación avisa que se buscó por texto',
      (tester) async {
    await _pumpResults(
      tester,
      NlSearchState(
        result: _result(
          query: 'nvidia',
          interpretation: null,
          source: CriteriaSource.textFallback,
          aiAvailable: false,
          results: [_match(symbol: 'NVDA', name: 'NVIDIA Corporation')],
          candidatesEvaluated: 1,
        ),
        isLoading: false,
      ),
    );

    // Presentar una búsqueda por coincidencia de texto como si fuera conversacional sería mentir
    // sobre lo que pasó.
    expect(find.text('BÚSQUEDA POR TEXTO'), findsOneWidget);
    expect(find.textContaining('sin interpretar la consulta'), findsOneWidget);
  });

  testWidgets('sin coincidencias explica cuántos candidatos se evaluaron', (
    tester,
  ) async {
    await _pumpResults(
      tester,
      NlSearchState(
        result: _result(candidatesEvaluated: 40),
        isLoading: false,
      ),
    );

    expect(find.textContaining('Se evaluaron 40 activos'), findsOneWidget);
  });

  testWidgets('un catálogo vacío se distingue de una búsqueda sin matches', (
    tester,
  ) async {
    // Sin el sync corrido en el backend, TODA búsqueda vuelve vacía y sin este texto parecería que
    // el buscador está roto.
    await _pumpResults(
      tester,
      NlSearchState(result: _result(candidatesEvaluated: 0), isLoading: false),
    );

    expect(find.textContaining('nunca se sincronizó'), findsOneWidget);
  });

  testWidgets('el estado inicial ofrece ejemplos tocables', (tester) async {
    // Una búsqueda conversacional sin ejemplos deja al usuario adivinando qué clase de frase
    // entiende, y la primera consulta fallida es la que hace que no vuelva a usarla.
    await _pumpResults(tester, NlSearchState.initial);

    expect(find.text('PROBÁ CON'), findsOneWidget);
    expect(find.text('tecnológicas grandes con poca deuda'), findsOneWidget);
  });

  testWidgets('un fallo de red se muestra como mensaje, no como lista vacía', (
    tester,
  ) async {
    await _pumpResults(
      tester,
      const NlSearchState(
        result: null,
        isLoading: false,
        errorMessage: 'No se pudo conectar con el servidor.',
      ),
    );

    expect(find.text('No se pudo conectar con el servidor.'), findsOneWidget);
    expect(find.text('PROBÁ CON'), findsNothing);
  });

  // --- El controller ------------------------------------------------------------------------

  ProviderContainer makeContainer(_FakeSearchRepository repository) {
    final container = ProviderContainer(
      overrides: [searchNlRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('una consulta muy corta no gasta un request', () async {
    // El backend exige 2 caracteres (422 si no): se corta antes para no gastar una llamada en algo
    // que ya se sabe inválido.
    final repository = _FakeSearchRepository(result: _result());
    final container = makeContainer(repository);

    await container.read(nlSearchControllerProvider.notifier).submit('a');
    await container.read(nlSearchControllerProvider.notifier).submit('   ');

    expect(repository.queries, isEmpty);
  });

  test('la consulta se envía sin espacios de sobra', () async {
    final repository = _FakeSearchRepository(result: _result());
    final container = makeContainer(repository);

    await container
        .read(nlSearchControllerProvider.notifier)
        .submit('  tecnológicas baratas  ');

    expect(repository.queries, ['tecnológicas baratas']);
    expect(container.read(nlSearchControllerProvider).result, isNotNull);
  });

  test('un error deja el mensaje y descarta el resultado viejo', () async {
    final repository = _FakeSearchRepository(
      error: DioException(
        requestOptions: RequestOptions(path: '/tickers/search-nl'),
        message: 'boom',
      ),
    );
    final container = makeContainer(repository);

    await container
        .read(nlSearchControllerProvider.notifier)
        .submit('tecnológicas');

    final state = container.read(nlSearchControllerProvider);
    expect(state.errorMessage, isNotNull);
    expect(state.result, isNull);
    expect(state.isLoading, isFalse);
  });

  test('una cancelación no se muestra como error', () async {
    // Cancelar es el resultado esperado de haber reformulado la consulta, no algo que contarle al
    // usuario.
    final token = CancelToken();
    final repository = _FakeSearchRepository(
      error: DioException(
        requestOptions: RequestOptions(path: '/tickers/search-nl'),
        type: DioExceptionType.cancel,
        error: token.cancelError,
      ),
    );
    final container = makeContainer(repository);

    await container.read(nlSearchControllerProvider.notifier).submit('nvidia');

    expect(container.read(nlSearchControllerProvider).errorMessage, isNull);
  });

  test('clear vuelve al estado inicial', () async {
    final repository = _FakeSearchRepository(result: _result());
    final container = makeContainer(repository);

    await container.read(nlSearchControllerProvider.notifier).submit('nvidia');
    expect(container.read(nlSearchControllerProvider).hasSearched, isTrue);

    container.read(nlSearchControllerProvider.notifier).clear();

    expect(container.read(nlSearchControllerProvider).hasSearched, isFalse);
  });
}
