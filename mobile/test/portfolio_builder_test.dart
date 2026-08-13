import 'package:financiero_app/core/providers.dart';
import 'package:financiero_app/core/theme/app_theme.dart';
import 'package:financiero_app/features/portfolio_builder/data/portfolio_builder_models.dart';
import 'package:financiero_app/features/portfolio_builder/data/portfolio_builder_repository.dart';
import 'package:financiero_app/features/portfolio_builder/data/portfolio_formatting.dart';
import 'package:financiero_app/features/portfolio_builder/data/portfolio_note_snippet.dart';
import 'package:financiero_app/features/portfolio_builder/presentation/portfolio_builder_controller.dart';
import 'package:financiero_app/features/portfolio_builder/widgets/allocation_pie.dart';
import 'package:financiero_app/features/portfolio_builder/widgets/budget_bar.dart';
import 'package:financiero_app/features/portfolio_builder/widgets/portfolio_metrics.dart';
import 'package:financiero_app/features/portfolio_builder/widgets/position_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Doble del repositorio: registra lo que se le pidió y devuelve lo que le digan.
class _FakeRepository implements PortfolioBuilderRepository {
  _FakeRepository({PortfolioSimulationResult? result})
      : response = result ?? _simulation();

  PortfolioSimulationResult response;

  /// Se asigna después de construir el doble (ver el test del fallo): el caso interesante es que la
  /// primera simulación funcione y la segunda falle.
  Object? error;
  final List<Map<String, dynamic>> payloads = [];

  @override
  Future<PortfolioSimulationResult> simulate(
    PortfolioSimulationRequest request,
  ) async {
    payloads.add(request.toJson());
    final failure = error;
    if (failure != null) throw failure;
    return response;
  }
}

Map<String, dynamic> _itemJson({
  String ticker = 'NVDA',
  String sector = 'TECNOLOGIA',
  String sectorLabel = 'Tecnología',
  double? marketPrice = 300.0,
  double? effectivePrice = 300.0,
  bool custom = false,
  int units = 20,
  double invested = 6000.0,
  double weight = 60.0,
  double? return1y = 12.5,
  String? note,
}) =>
    {
      'ticker': ticker,
      'name': '$ticker Inc.',
      'sector': sector,
      'sector_label': sectorLabel,
      'market_price': marketPrice,
      'effective_price': effectivePrice,
      'is_custom_price': custom,
      'price_source': custom
          ? 'CUSTOM'
          : (marketPrice == null ? 'UNAVAILABLE' : 'MARKET'),
      'units': units,
      'invested_amount': invested,
      'percentage_of_total': weight,
      'return_1y_pct': return1y,
      'return_1y_from_date': return1y == null ? null : '2025-08-13',
      'note': note,
    };

PortfolioSimulationResult _simulation({
  List<Map<String, dynamic>>? items,
  List<Map<String, dynamic>>? sectors,
  double budget = 10000.0,
  double allocated = 9000.0,
  double cash = 1000.0,
  double cashPct = 10.0,
  double? overBudget,
  double? portfolioReturn = 11.0,
  double coverage = 100.0,
  String? risk = 'ALTA',
  double? herfindahl = 0.52,
  List<String> riskNotes = const [],
  String availability = 'AVAILABLE',
  String? reason,
  List<String> notes = const ['Las unidades se redondean hacia abajo a enteros.'],
}) =>
    PortfolioSimulationResult.fromJson({
      'generated_at': '2026-08-13T12:00:00Z',
      'total_budget': budget,
      'allocated_amount': allocated,
      'cash_unallocated': cash,
      'cash_pct': cashPct,
      'over_budget_amount': overBudget,
      'items': items ??
          [
            _itemJson(),
            _itemJson(
              ticker: 'KO',
              sector: 'CONSUMO_BASICO',
              sectorLabel: 'Consumo básico',
              marketPrice: 60.0,
              effectivePrice: 60.0,
              units: 50,
              invested: 3000.0,
              weight: 33.33,
              return1y: 4.0,
            ),
          ],
      'sector_allocation': sectors ??
          [
            {
              'sector': 'TECNOLOGIA',
              'label': 'Tecnología',
              'amount': 6000.0,
              'percentage_of_total': 66.67,
              'ticker_count': 1,
              'tickers': ['NVDA'],
            },
            {
              'sector': 'CONSUMO_BASICO',
              'label': 'Consumo básico',
              'amount': 3000.0,
              'percentage_of_total': 33.33,
              'ticker_count': 1,
              'tickers': ['KO'],
            },
          ],
      'weighting_basis': 'MARKET_VALUE',
      'portfolio_return_1y_pct': portfolioReturn,
      'return_coverage_pct': coverage,
      'risk_score': risk,
      'herfindahl_index': herfindahl,
      'top_sector': 'TECNOLOGIA',
      'top_sector_weight_pct': 66.67,
      'risk_notes': riskNotes,
      'unit_rounding': 'FLOOR_TO_WHOLE_UNITS',
      'availability': availability,
      'degradation_reason': reason,
      'notes': notes,
    });

Future<ProviderContainer> _container(_FakeRepository repository) async {
  final container = ProviderContainer(
    overrides: [portfolioBuilderRepositoryProvider.overrideWithValue(repository)],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required _FakeRepository repository,
  Size size = const Size(1400, 1000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        portfolioBuilderRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(theme: AppTheme.dark, home: Scaffold(body: child)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // --- Modelos ---------------------------------------------------------------------------------

  group('Parseo de los modelos', () {
    test('un entero del JSON se convierte a double sin explotar', () {
      final result = PortfolioSimulationResult.fromJson({
        'generated_at': '2026-08-13T12:00:00Z',
        'total_budget': 10000,
        'allocated_amount': 9000,
        'cash_unallocated': 1000,
        'cash_pct': 10,
        'availability': 'AVAILABLE',
      });

      expect(result.totalBudget, 10000.0);
      expect(result.cashPct, 10.0);
    });

    test('un enum desconocido degrada ese campo sin tirar la respuesta', () {
      final result = _simulation(risk: 'INVENTADO');
      expect(result.riskScore, isNull);
      // El resto del reparto sobrevive: un nivel que no se entiende no debería vaciar la pantalla.
      expect(result.allocatedAmount, 9000.0);
    });

    test('una posición sin capital se separa de las financiadas', () {
      final result = _simulation(
        items: [
          _itemJson(),
          _itemJson(
            ticker: 'BRK',
            units: 0,
            invested: 0,
            weight: 0,
            note: 'No alcanza para una unidad entera.',
          ),
        ],
      );

      expect(result.funded.map((item) => item.ticker), ['NVDA']);
      expect(result.unfunded.map((item) => item.ticker), ['BRK']);
    });

    test('las financiadas se ordenan de mayor a menor peso', () {
      final result = _simulation(
        items: [
          _itemJson(ticker: 'CHICA', invested: 1000.0),
          _itemJson(ticker: 'GRANDE', invested: 8000.0),
        ],
      );

      expect(result.funded.map((item) => item.ticker), ['GRANDE', 'CHICA']);
    });

    test('la cobertura parcial se distingue de la completa', () {
      expect(_simulation(coverage: 100.0).returnIsComplete, isTrue);
      expect(_simulation(coverage: 60.0).returnIsComplete, isFalse);
    });

    test('el exceso sobre el presupuesto se reconoce', () {
      expect(_simulation().isOverBudget, isFalse);
      expect(_simulation(overBudget: 500.0).isOverBudget, isTrue);
    });

    test('la distancia del precio esperado contra el mercado se calcula', () {
      final result = _simulation(
        items: [
          _itemJson(marketPrice: 300.0, effectivePrice: 240.0, custom: true),
        ],
      );

      // 240 contra 300 es 20% abajo.
      expect(result.items.first.customPriceGapPct, closeTo(-20.0, 0.001));
    });

    test('sin precio de mercado no se inventa una distancia', () {
      final result = _simulation(
        items: [
          _itemJson(marketPrice: null, effectivePrice: 240.0, custom: true),
        ],
      );

      expect(result.items.first.customPriceGapPct, isNull);
    });
  });

  group('Serialización del pedido', () {
    test('sin precio esperado la clave NO viaja', () {
      // Mandar `null` explícito sería fijarlo en null, y el backend lo rechaza con 422.
      const item = PortfolioItemInput(
        ticker: 'NVDA',
        allocationType: AllocationType.percentage,
        allocationValue: 50,
      );

      expect(item.toJson().containsKey('custom_price'), isFalse);
    });

    test('con precio esperado la clave viaja', () {
      const item = PortfolioItemInput(
        ticker: 'NVDA',
        allocationType: AllocationType.percentage,
        allocationValue: 50,
        customPrice: 250,
      );

      expect(item.toJson()['custom_price'], 250);
    });

    test('el tipo de activo viaja en el vocabulario del PRODUCTO', () {
      // El buscador entrega el tipo CRUDO de Polygon (`CS`, `ETF`…), que no es el `AssetType` del
      // producto: reenviarlo hacía que el backend rechazara la simulación entera con un 422.
      const item = PortfolioItemInput(
        ticker: 'NVDA',
        allocationType: AllocationType.units,
        allocationValue: 1,
      );

      expect(item.toJson()['asset_type'], anyOf('STOCK', 'CRYPTO'));
    });

    test('el tipo de asignación viaja en el vocabulario del backend', () {
      const item = PortfolioItemInput(
        ticker: 'NVDA',
        allocationType: AllocationType.amountUsd,
        allocationValue: 1000,
      );

      expect(item.toJson()['allocation_type'], 'AMOUNT_USD');
    });

    test('dos pedidos iguales son el mismo', () {
      const a = PortfolioSimulationRequest(
        totalBudget: 1000,
        items: [
          PortfolioItemInput(
            ticker: 'NVDA',
            allocationType: AllocationType.units,
            allocationValue: 5,
          ),
        ],
      );
      const b = PortfolioSimulationRequest(
        totalBudget: 1000,
        items: [
          PortfolioItemInput(
            ticker: 'NVDA',
            allocationType: AllocationType.units,
            allocationValue: 5,
          ),
        ],
      );

      expect(a, b);
    });

    test('cambiar el presupuesto cambia el pedido', () {
      const a = PortfolioSimulationRequest(totalBudget: 1000, items: []);
      const b = PortfolioSimulationRequest(totalBudget: 2000, items: []);
      expect(a == b, isFalse);
    });
  });

  // --- Borrador --------------------------------------------------------------------------------

  group('PortfolioDraftController', () {
    test('agregar dos veces el mismo símbolo no duplica la fila', () async {
      final container = await _container(_FakeRepository());
      final controller = container.read(portfolioDraftProvider.notifier);

      controller.add('NVDA');
      controller.add('nvda');

      expect(container.read(portfolioDraftProvider).items.length, 1);
    });

    test('el símbolo se normaliza a mayúsculas', () async {
      final container = await _container(_FakeRepository());
      container.read(portfolioDraftProvider.notifier).add(' nvda ');

      expect(container.read(portfolioDraftProvider).items.first.ticker, 'NVDA');
    });

    test('cambiar el tipo reinicia el valor al default del tipo nuevo', () async {
      // Conservar el 10 al pasar de unidades a porcentaje cambiaría el significado del número sin
      // que el usuario lo pida.
      final container = await _container(_FakeRepository());
      final controller = container.read(portfolioDraftProvider.notifier);

      controller.add('NVDA', type: AllocationType.units);
      controller.setValue('NVDA', 500);
      controller.setType('NVDA', AllocationType.amountUsd);

      final item = container.read(portfolioDraftProvider).items.first;
      expect(item.allocationType, AllocationType.amountUsd);
      expect(item.allocationValue, defaultAllocationValue(AllocationType.amountUsd));
    });

    test('re-elegir el mismo tipo no pisa el valor', () async {
      final container = await _container(_FakeRepository());
      final controller = container.read(portfolioDraftProvider.notifier);

      controller.add('NVDA', type: AllocationType.units);
      controller.setValue('NVDA', 500);
      controller.setType('NVDA', AllocationType.units);

      expect(container.read(portfolioDraftProvider).items.first.allocationValue, 500);
    });

    test('apagar el precio esperado lo vuelve a null, no a cero', () async {
      final container = await _container(_FakeRepository());
      final controller = container.read(portfolioDraftProvider.notifier);

      controller.add('NVDA');
      controller.setCustomPrice('NVDA', 250);
      expect(container.read(portfolioDraftProvider).items.first.customPrice, 250);

      controller.setCustomPrice('NVDA', null);
      expect(container.read(portfolioDraftProvider).items.first.customPrice, isNull);
    });

    test('un precio esperado de cero se trata como sin fijar', () async {
      // El backend rechaza `custom_price: 0` con 422: se traduce a "usá el mercado" antes de mandar.
      final container = await _container(_FakeRepository());
      final controller = container.read(portfolioDraftProvider.notifier);

      controller.add('NVDA');
      controller.setCustomPrice('NVDA', 0);

      expect(container.read(portfolioDraftProvider).items.first.customPrice, isNull);
    });

    test('el presupuesto se recorta al máximo del backend', () async {
      final container = await _container(_FakeRepository());
      container.read(portfolioDraftProvider.notifier).setBudget(1e12);

      expect(container.read(portfolioDraftProvider).totalBudget, kMaxBudgetUsd);
    });

    test('no se pasa del tope de posiciones', () async {
      final container = await _container(_FakeRepository());
      final controller = container.read(portfolioDraftProvider.notifier);

      for (var index = 0; index < kMaxPortfolioItems + 5; index++) {
        controller.add('T$index');
      }

      expect(
        container.read(portfolioDraftProvider).items.length,
        kMaxPortfolioItems,
      );
    });

    test('la suma de porcentajes ignora los otros tipos', () async {
      final container = await _container(_FakeRepository());
      final controller = container.read(portfolioDraftProvider.notifier);

      controller.add('NVDA', type: AllocationType.percentage);
      controller.setValue('NVDA', 60);
      controller.add('KO', type: AllocationType.amountUsd);
      controller.setValue('KO', 3000);

      expect(container.read(portfolioDraftProvider).requestedPercentage, 60);
    });

    test('sacar un símbolo lo quita de la lista', () async {
      final container = await _container(_FakeRepository());
      final controller = container.read(portfolioDraftProvider.notifier);

      controller.add('NVDA');
      controller.add('KO');
      controller.remove('NVDA');

      expect(
        container.read(portfolioDraftProvider).items.map((item) => item.ticker),
        ['KO'],
      );
    });
  });

  // --- Simulación ------------------------------------------------------------------------------

  group('PortfolioSimulationController', () {
    test('manda el presupuesto y las posiciones tal como están', () async {
      final repository = _FakeRepository();
      final container = await _container(repository);
      final draft = container.read(portfolioDraftProvider.notifier);

      draft.setBudget(5000);
      draft.add('NVDA', type: AllocationType.percentage);
      await container.read(portfolioSimulationProvider.notifier).run();

      expect(repository.payloads.single['total_budget'], 5000.0);
      final items = repository.payloads.single['items'] as List<dynamic>;
      expect((items.single as Map<String, dynamic>)['ticker'], 'NVDA');
    });

    test('sin posiciones no se llama al backend', () async {
      final repository = _FakeRepository();
      final container = await _container(repository);

      await container.read(portfolioSimulationProvider.notifier).run();

      expect(repository.payloads, isEmpty);
    });

    test('un fallo conserva el resultado anterior con su error', () async {
      final repository = _FakeRepository();
      final container = await _container(repository);
      container.read(portfolioDraftProvider.notifier).add('NVDA');

      await container.read(portfolioSimulationProvider.notifier).run();
      expect(container.read(portfolioSimulationProvider).hasResult, isTrue);

      repository.error = Exception('sin red');
      await container.read(portfolioSimulationProvider.notifier).run();

      final state = container.read(portfolioSimulationProvider);
      // Borrar el reparto ante un error de red dejaría la pantalla en blanco sin ganar nada.
      expect(state.hasResult, isTrue);
      expect(state.errorMessage, isNotNull);
    });

    test('avisa cuando el resultado quedó viejo respecto del borrador', () async {
      final repository = _FakeRepository();
      final container = await _container(repository);
      final draft = container.read(portfolioDraftProvider.notifier);

      draft.add('NVDA');
      await container.read(portfolioSimulationProvider.notifier).run();

      final before = container.read(portfolioDraftProvider).toRequest();
      expect(
        container.read(portfolioSimulationProvider).isStale(before),
        isFalse,
      );

      draft.setBudget(50000);
      final after = container.read(portfolioDraftProvider).toRequest();
      expect(container.read(portfolioSimulationProvider).isStale(after), isTrue);
    });
  });

  // --- Formato ---------------------------------------------------------------------------------

  group('Formato de montos', () {
    test('el separador de miles es rioplatense', () {
      expect(formatUsd(12500.5), r'US$ 12.500,50');
    });

    test('un monto negativo usa el menos tipográfico', () {
      expect(formatUsd(-1200), r'−US$ 1.200,00');
    });

    test('un peso de cartera no lleva signo de variación', () {
      // "40%" es un nivel; "+40%" se leería como "40 puntos más que antes".
      expect(formatWeightPct(40), '40,0%');
    });

    test('un monto ausente no se muestra como cero', () {
      expect(formatUsd(null), '—');
    });
  });

  // --- Widgets ---------------------------------------------------------------------------------

  group('Barra de presupuesto', () {
    testWidgets('muestra el efectivo sin asignar', (tester) async {
      await _pump(
        tester,
        BudgetBar(result: _simulation()),
        repository: _FakeRepository(),
      );

      expect(find.text('SIN ASIGNAR'), findsOneWidget);
      expect(find.textContaining(r'US$ 1.000,00'), findsOneWidget);
    });

    testWidgets('con exceso muestra el exceso y NO el efectivo', (tester) async {
      // Una cartera no puede tener sobrante y pasarse a la vez: mostrar los dos obligaría a leer
      // cuál está activo.
      await _pump(
        tester,
        BudgetBar(result: _simulation(overBudget: 600, cash: 0, cashPct: 0)),
        repository: _FakeRepository(),
      );

      expect(find.text('EXCESO'), findsOneWidget);
      expect(find.text('SIN ASIGNAR'), findsNothing);
    });

    testWidgets('sin resultado solo se ve el campo de presupuesto', (tester) async {
      await _pump(tester, const BudgetBar(), repository: _FakeRepository());

      expect(find.text('ASIGNADO'), findsNothing);
      expect(find.text('Presupuesto'), findsOneWidget);
    });
  });

  group('Fila de posición', () {
    testWidgets('arranca en precio de mercado, no en precio esperado',
        (tester) async {
      await _pump(
        tester,
        const PositionRow(
          item: PortfolioItemInput(
            ticker: 'NVDA',
            allocationType: AllocationType.percentage,
            allocationValue: 50,
          ),
          resolved: null,
        ),
        repository: _FakeRepository(),
      );

      expect(find.text('Precio de mercado'), findsOneWidget);
      expect(find.text('Precio esperado'), findsNothing);
      expect(
        find.textContaining('se calcula con la última cotización'),
        findsOneWidget,
      );
    });

    testWidgets('con precio esperado aparece el campo y el título cambia',
        (tester) async {
      await _pump(
        tester,
        const PositionRow(
          item: PortfolioItemInput(
            ticker: 'NVDA',
            allocationType: AllocationType.percentage,
            allocationValue: 50,
            customPrice: 250,
          ),
          resolved: null,
        ),
        repository: _FakeRepository(),
      );

      expect(find.text('Precio esperado'), findsOneWidget);
      expect(
        find.textContaining('en lugar del de mercado'),
        findsOneWidget,
      );
    });

    testWidgets('la distancia contra el mercado se dice en palabras',
        (tester) async {
      final resolved = _simulation(
        items: [
          _itemJson(marketPrice: 300.0, effectivePrice: 240.0, custom: true),
        ],
      ).items.first;

      await _pump(
        tester,
        PositionRow(
          item: const PortfolioItemInput(
            ticker: 'NVDA',
            allocationType: AllocationType.percentage,
            allocationValue: 50,
            customPrice: 240,
          ),
          resolved: resolved,
        ),
        repository: _FakeRepository(),
      );

      expect(
        find.textContaining('respecto del de mercado'),
        findsOneWidget,
      );
    });

    testWidgets('una posición en cero muestra su motivo', (tester) async {
      final resolved = _simulation(
        items: [
          _itemJson(
            ticker: 'BRK',
            units: 0,
            invested: 0,
            weight: 0,
            note: 'No alcanza para una unidad entera.',
          ),
        ],
      ).items.first;

      await _pump(
        tester,
        PositionRow(
          item: const PortfolioItemInput(
            ticker: 'BRK',
            allocationType: AllocationType.percentage,
            allocationValue: 50,
          ),
          resolved: resolved,
        ),
        repository: _FakeRepository(),
      );

      expect(find.text('No alcanza para una unidad entera.'), findsOneWidget);
    });
  });

  group('Torta de asignación', () {
    testWidgets('la leyenda nombra cada porción', (tester) async {
      await _pump(
        tester,
        AllocationPie(result: _simulation(), mode: PieMode.asset),
        repository: _FakeRepository(),
      );

      expect(find.text('NVDA'), findsOneWidget);
      expect(find.text('KO'), findsOneWidget);
    });

    testWidgets('en modo sector nombra sectores y no activos', (tester) async {
      await _pump(
        tester,
        AllocationPie(result: _simulation(), mode: PieMode.sector),
        repository: _FakeRepository(),
      );

      expect(find.text('Tecnología'), findsOneWidget);
      expect(find.text('NVDA'), findsNothing);
    });

    testWidgets('el centro muestra el total mientras no se toque nada',
        (tester) async {
      await _pump(
        tester,
        AllocationPie(result: _simulation(), mode: PieMode.asset),
        repository: _FakeRepository(),
      );

      expect(find.text('asignado'), findsOneWidget);
      expect(find.text('100,0%'), findsOneWidget);
    });

    testWidgets('sin posiciones financiadas no se dibuja nada', (tester) async {
      final empty = _simulation(
        items: [_itemJson(units: 0, invested: 0, weight: 0)],
        sectors: const [],
      );

      await _pump(
        tester,
        AllocationPie(result: empty, mode: PieMode.asset),
        repository: _FakeRepository(),
      );

      expect(find.byType(AllocationPie), findsOneWidget);
      expect(find.text('asignado'), findsNothing);
    });
  });

  group('Métricas', () {
    testWidgets('el badge de riesgo dice qué sector domina', (tester) async {
      await _pump(
        tester,
        RiskBadge(result: _simulation()),
        repository: _FakeRepository(),
      );

      expect(find.textContaining('Concentración alta'), findsOneWidget);
      expect(find.textContaining('Tecnología concentra'), findsOneWidget);
    });

    testWidgets('el badge declara que el nivel sale de umbrales en código',
        (tester) async {
      await _pump(
        tester,
        RiskBadge(result: _simulation()),
        repository: _FakeRepository(),
      );

      expect(find.textContaining('umbrales fijos'), findsOneWidget);
      expect(find.textContaining('Auditoría de Portafolio'), findsOneWidget);
    });

    testWidgets('sin nivel no se muestra badge', (tester) async {
      await _pump(
        tester,
        RiskBadge(result: _simulation(risk: null)),
        repository: _FakeRepository(),
      );

      expect(find.textContaining('Concentración'), findsNothing);
    });

    testWidgets('una cobertura parcial se declara', (tester) async {
      await _pump(
        tester,
        ReturnCard(result: _simulation(coverage: 60)),
        repository: _FakeRepository(),
      );

      expect(find.textContaining('60,0% del capital'), findsOneWidget);
      expect(find.textContaining('NO se contó como 0%'), findsOneWidget);
    });

    testWidgets('una cobertura completa no arrastra la advertencia',
        (tester) async {
      await _pump(
        tester,
        ReturnCard(result: _simulation(coverage: 100)),
        repository: _FakeRepository(),
      );

      expect(find.text('Medido sobre todo el capital asignado.'), findsOneWidget);
      expect(find.textContaining('NO se contó como 0%'), findsNothing);
    });

    testWidgets('sin retorno medible se dice el motivo, no un 0%',
        (tester) async {
      await _pump(
        tester,
        ReturnCard(result: _simulation(portfolioReturn: null, coverage: 0)),
        repository: _FakeRepository(),
      );

      expect(
        find.textContaining('Ninguna posición tenía histórico suficiente'),
        findsOneWidget,
      );
    });

    testWidgets('se aclara que el retorno es histórico y no proyección',
        (tester) async {
      await _pump(
        tester,
        ReturnCard(result: _simulation()),
        repository: _FakeRepository(),
      );

      expect(find.text('Es lo que pasó, no una proyección.'), findsOneWidget);
    });
  });

  // --- Nota del Lab ----------------------------------------------------------------------------

  group('Nota del Investment Lab', () {
    test('transcribe posiciones, sectores y concentración', () {
      final markdown = buildPortfolioNoteMarkdown(_simulation());

      expect(markdown, contains('| NVDA |'));
      expect(markdown, contains('Tecnología'));
      expect(markdown, contains('**Concentración alta**'));
      expect(markdown, contains('Herfindahl'));
    });

    test('marca qué precios eran esperados', () {
      // Sin esa marca, seis meses después no se sabe si el reparto se hizo con precios reales.
      final markdown = buildPortfolioNoteMarkdown(
        _simulation(
          items: [_itemJson(custom: true, effectivePrice: 250.0)],
        ),
      );

      expect(markdown, contains('(esperado)'));
    });

    test('declara sobre qué base se ponderaron los sectores', () {
      final markdown = buildPortfolioNoteMarkdown(_simulation());

      expect(markdown, contains('MARKET_VALUE'));
      expect(markdown, contains('no por cantidad de símbolos'));
    });

    test('la cobertura parcial queda escrita en la nota', () {
      final markdown = buildPortfolioNoteMarkdown(_simulation(coverage: 60));

      expect(markdown, contains('NO se contó como 0%'));
    });

    test('el exceso sobre el presupuesto se transcribe', () {
      final markdown =
          buildPortfolioNoteMarkdown(_simulation(overBudget: 600, cash: 0));

      expect(markdown, contains('Excedente sobre el presupuesto'));
      expect(markdown, contains('no se recortó ninguna posición'));
    });

    test('una cartera sin asignar deja constancia en vez de quedar vacía', () {
      final markdown = buildPortfolioNoteMarkdown(
        _simulation(
          items: [_itemJson(units: 0, invested: 0, weight: 0)],
          sectors: const [],
          reason: 'Sin precios en este entorno.',
        ),
      );

      expect(markdown, contains('Ninguna posición quedó con capital asignado'));
    });

    test('las posiciones sin capital se listan con su motivo', () {
      final markdown = buildPortfolioNoteMarkdown(
        _simulation(
          items: [
            _itemJson(),
            _itemJson(
              ticker: 'BRK',
              units: 0,
              invested: 0,
              weight: 0,
              note: 'No alcanza para una unidad entera.',
            ),
          ],
        ),
      );

      expect(markdown, contains('Sin capital asignado'));
      expect(markdown, contains('BRK: No alcanza para una unidad entera.'));
    });

    test('aclara que es una simulación y no una cartera real', () {
      final markdown = buildPortfolioNoteMarkdown(_simulation());

      expect(markdown, contains('no hay órdenes, comisiones ni impuestos'));
    });

    test('el título describe tamaño y concentración, no la fecha', () {
      final draft = portfolioNoteDraft(_simulation());

      expect(draft.title, contains('2 activos'));
      expect(draft.title, contains('Tecnología'));
    });
  });
}
