import 'package:financiero_app/core/providers.dart';
import 'package:financiero_app/core/theme/app_theme.dart';
import 'package:financiero_app/features/watchlist/data/portfolio_audit.dart';
import 'package:financiero_app/features/watchlist/data/watchlist_audit_repository.dart';
import 'package:financiero_app/features/watchlist/widgets/audit_sections.dart';
import 'package:financiero_app/features/watchlist/widgets/portfolio_audit_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests de la Auditoría de Portafolio: parseo del contrato y comportamiento de la hoja.
///
/// Los tres contratos que la UI promete y que son fáciles de romper sin darse cuenta:
///
///   1. **Los porcentajes son cantidad de activos, no dinero.** La aclaración tiene que estar
///      SIEMPRE y arriba: sin ella, toda la hoja se lee como plata invertida.
///   2. **Una advertencia medida y una inferida por sector se ven distinto**, y la ausencia de
///      advertencias dice cosas opuestas según se haya podido medir o no.
///   3. **Ningún bloque se esconde**: cada sección degrada con su banner en vez de desaparecer.
///
/// El doble es el repositorio (con `implements`, para no arrastrar el `ApiClient` del
/// constructor): así se ejercita también el controller, que es quien distingue "abrir" (GET,
/// respeta caché) de "recalcular" (POST, la ignora) — la razón de que no sea un `FutureProvider`.

class _FakeAuditRepository implements WatchlistAuditRepository {
  _FakeAuditRepository({
    required this.audit,
    this.refreshed,
    this.failGet = false,
  });

  final PortfolioAudit audit;
  final PortfolioAudit? refreshed;
  final bool failGet;

  int getCalls = 0;
  int refreshCalls = 0;

  @override
  Future<PortfolioAudit> getAudit() async {
    getCalls++;
    if (failGet) throw Exception('sin red');
    return audit;
  }

  @override
  Future<PortfolioAudit> refreshAudit() async {
    refreshCalls++;
    return refreshed ?? audit;
  }
}

PortfolioAudit _audit({
  int positionCount = 3,
  DataAvailability availability = DataAvailability.available,
  List<SectorAllocation> sectors = const [],
  bool sectorDataAvailable = true,
  ConcentrationRisk? risk,
  List<CorrelationWarning> warnings = const [],
  bool correlationMeasured = true,
  List<DiversificationSuggestion> suggestions = const [],
  String? aiSummary,
  String? degradationReason,
  bool servedFromCache = false,
}) =>
    PortfolioAudit(
      generatedAt: DateTime.utc(2026, 8, 5, 12),
      positionCount: positionCount,
      weightingBasis: 'EQUAL_WEIGHT_BY_COUNT',
      availability: availability,
      sectorAllocation: sectors,
      sectorDataAvailable: sectorDataAvailable,
      riskConcentration: risk,
      correlationWarnings: warnings,
      correlationMeasured: correlationMeasured,
      diversificationSuggestions: suggestions,
      aiSummary: aiSummary,
      aiSummaryAvailable: aiSummary != null,
      degradationReason: degradationReason,
      servedFromCache: servedFromCache,
    );

SectorAllocation _allocation(
  PortfolioSector sector,
  String label,
  double weight,
  List<String> tickers,
) =>
    SectorAllocation(
      sector: sector,
      label: label,
      weightPct: weight,
      tickerCount: tickers.length,
      tickers: tickers,
    );

Future<void> _pumpSheet(
  WidgetTester tester,
  _FakeAuditRepository repository, {
  Key? scopeKey,
}) async {
  // Viewport alto: la hoja tiene cinco secciones y en los 600x800 por defecto la última queda
  // fuera del área renderizada, así que un `findsOneWidget` sobre ella fallaría por scroll y no
  // porque el widget no esté.
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      key: scopeKey,
      overrides: [
        watchlistAuditRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        theme: AppTheme.dark,
        home: const Scaffold(body: PortfolioAuditSheet()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // --- Parseo del contrato -----------------------------------------------------------------

  group('PortfolioAudit.fromJson', () {
    test('lee la respuesta completa del backend', () {
      final audit = PortfolioAudit.fromJson(const {
        'generated_at': '2026-08-05T12:00:00Z',
        'position_count': 7,
        'weighting_basis': 'EQUAL_WEIGHT_BY_COUNT',
        'availability': 'AVAILABLE',
        'sector_allocation': [
          {
            'sector': 'TECNOLOGIA',
            'label': 'Tecnología',
            'weight_pct': 42.86,
            'ticker_count': 3,
            'tickers': ['AAPL', 'MSFT', 'NVDA'],
          },
        ],
        'sector_data_available': true,
        'risk_concentration': {
          'level': 'MODERADA',
          'headline': '43% concentrado en Tecnología — riesgo moderado',
          'top_sector': 'TECNOLOGIA',
          'top_sector_label': 'Tecnología',
          'top_sector_weight_pct': 42.86,
          'distinct_sectors': 5,
          'herfindahl_index': 0.2654,
          'notes': ['Nota de prueba.'],
        },
        'correlation_warnings': [
          {
            'tickers': ['AAPL', 'MSFT'],
            'basis': 'PRICE_HISTORY',
            'coefficient': 0.91,
            'observations': 58,
            'message': 'Se movieron casi igual.',
          },
        ],
        'correlation_measured': true,
        'diversification_suggestions': [
          {
            'sector': 'SALUD',
            'label': 'Salud',
            'rationale': 'No seguís Salud.'
          },
        ],
        'ai_summary': 'Tu lista se apoya en Tecnología.',
        'ai_summary_available': true,
        'degradation_reason': null,
        'served_from_cache': true,
      });

      expect(audit.positionCount, 7);
      expect(audit.isEqualWeighted, isTrue);
      expect(audit.sectorAllocation.single.sector, PortfolioSector.tecnologia);
      expect(audit.sectorAllocation.single.tickers, ['AAPL', 'MSFT', 'NVDA']);
      expect(audit.riskConcentration!.level, RiskLevel.moderada);
      expect(audit.riskConcentration!.herfindahlIndex, closeTo(0.2654, 0.0001));
      expect(audit.correlationWarnings.single.isMeasured, isTrue);
      expect(
          audit.correlationWarnings.single.coefficient, closeTo(0.91, 0.001));
      expect(audit.diversificationSuggestions.single.sector,
          PortfolioSector.salud);
      expect(audit.aiSummaryAvailable, isTrue);
      expect(audit.servedFromCache, isTrue);
    });

    test('un sector desconocido cae en sinClasificar en vez de romper', () {
      // El backend puede agregar un sector nuevo sin que la app se actualice: ese dato puntual
      // degrada, no tira abajo la auditoría entera.
      expect(sectorFromWire('BIOTECNOLOGIA_CUANTICA'),
          PortfolioSector.sinClasificar);
      expect(sectorFromWire(null), PortfolioSector.sinClasificar);
    });

    test('un nivel de riesgo desconocido cae en moderada, no en baja', () {
      // Ante un valor que este cliente no conoce, la afirmación prudente no es "tu cartera está
      // bien".
      expect(riskLevelFromWire('EXTREMA'), RiskLevel.moderada);
      expect(riskLevelFromWire(null), RiskLevel.moderada);
    });

    test('una base de correlación desconocida se degrada a heurística', () {
      // `sector` es la afirmación más débil: un valor inesperado no puede terminar presentando una
      // inferencia como si fuera una medición.
      expect(correlationBasisFromWire('CORRELACION_MAGICA'),
          CorrelationBasis.sector);
      expect(correlationBasisFromWire('PRICE_HISTORY'),
          CorrelationBasis.priceHistory);
    });

    test('una advertencia por sector no trae coeficiente inventado', () {
      final warning = CorrelationWarning.fromJson(const {
        'tickers': ['JPM', 'BAC'],
        'basis': 'SECTOR',
        'coefficient': null,
        'observations': null,
        'message': 'Comparten sector.',
      });

      expect(warning.isMeasured, isFalse);
      expect(warning.coefficient, isNull);
      expect(warning.observations, isNull);
    });
  });

  // --- La hoja ------------------------------------------------------------------------------

  testWidgets('muestra síntesis, distribución, riesgo y sugerencias', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      _FakeAuditRepository(
        audit: _audit(
          positionCount: 4,
          aiSummary: 'Tu lista se apoya sobre todo en Tecnología.',
          sectors: [
            _allocation(PortfolioSector.tecnologia, 'Tecnología', 75,
                ['AAPL', 'MSFT', 'NVDA']),
            _allocation(PortfolioSector.salud, 'Salud', 25, ['JNJ']),
          ],
          risk: const ConcentrationRisk(
            level: RiskLevel.critica,
            headline: '75% concentrado en Tecnología — riesgo muy alto',
            topSector: PortfolioSector.tecnologia,
            topSectorLabel: 'Tecnología',
            topSectorWeightPct: 75,
            distinctSectors: 2,
            herfindahlIndex: 0.625,
            notes: ['Toda la cartera se reparte entre dos sectores.'],
          ),
          suggestions: const [
            DiversificationSuggestion(
              sector: PortfolioSector.energia,
              label: 'Energía',
              rationale: 'No seguís ningún activo de Energía.',
            ),
          ],
        ),
      ),
    );

    expect(find.text('Tu lista se apoya sobre todo en Tecnología.'),
        findsOneWidget);
    expect(find.text('75% concentrado en Tecnología — riesgo muy alto'),
        findsOneWidget);
    expect(find.text('RIESGO MUY ALTO'), findsOneWidget);
    expect(find.text('75.0%'), findsOneWidget);
    expect(find.text('NVDA'), findsOneWidget);
    expect(find.text('Energía'), findsOneWidget);
    expect(find.text('0.63'), findsOneWidget); // índice HHI (0.625 redondeado)
  });

  testWidgets('la barra apilada se dibuja con alto real, no colapsada', (
    tester,
  ) async {
    // Un `ColoredBox` sin hijo adopta el mínimo de la restricción del `Row`, que en el eje
    // transversal es suelta: sin `CrossAxisAlignment.stretch` la barra queda de alto 0 y
    // desaparece sin que nada falle. Se mide el alto renderizado para que no vuelva a pasar.
    await _pumpSheet(
      tester,
      _FakeAuditRepository(
        audit: _audit(
          sectors: [
            _allocation(PortfolioSector.tecnologia, 'Tecnología', 75, ['NVDA']),
            _allocation(PortfolioSector.salud, 'Salud', 25, ['JNJ']),
          ],
        ),
      ),
    );

    // Se buscan por color y no por tipo: el árbol tiene otros `ColoredBox` (del `Scaffold`, del
    // clip) que no son tramos de la barra.
    Finder segment(PortfolioSector sector) => find.byWidgetPredicate(
          (widget) =>
              widget is ColoredBox && widget.color == sectorColor(sector),
        );

    final tech = tester.getSize(segment(PortfolioSector.tecnologia));
    final salud = tester.getSize(segment(PortfolioSector.salud));

    expect(tech.height, 12);
    expect(salud.height, 12);
    // Y el reparto respeta el peso: el tramo del 75% es más ancho que el del 25%.
    expect(tech.width, greaterThan(salud.width));
  });

  testWidgets('aclara siempre que la ponderación es por cantidad de activos', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      _FakeAuditRepository(
        audit: _audit(
          sectors: [
            _allocation(PortfolioSector.tecnologia, 'Tecnología', 100,
                ['NVDA', 'AAPL', 'MSFT']),
          ],
        ),
      ),
    );

    // Es la aclaración que evita que "100% en Tecnología" se lea como plata invertida. Va arriba
    // de todo a propósito: decirla al pie llegaría después de que el usuario ya leyó la torta.
    expect(
      find.textContaining('no sobre el dinero invertido', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('3 activos seguidos', findRichText: true),
        findsOneWidget);
  });

  testWidgets('sin narrativa muestra el motivo en vez de un hueco', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      _FakeAuditRepository(
        audit: _audit(
          availability: DataAvailability.partial,
          sectors: [
            _allocation(PortfolioSector.cripto, 'Cripto', 100, ['BTC-USD']),
          ],
          degradationReason:
              'La narrativa con IA no está configurada en este entorno.',
        ),
      ),
    );

    // La sección no desaparece: muestra su banner. Una tarjeta ausente se lee como un bug.
    expect(find.text('Síntesis del agente'), findsOneWidget);
    expect(
      find.text('La narrativa con IA no está configurada en este entorno.'),
      findsOneWidget,
    );
    // Y lo determinístico sigue estando.
    expect(find.text('Distribución por sectores'), findsOneWidget);
    expect(find.text('Cripto'), findsOneWidget);
  });

  testWidgets('distingue una correlación medida de una inferida por sector', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      _FakeAuditRepository(
        audit: _audit(
          warnings: const [
            CorrelationWarning(
              tickers: ['AAPL', 'MSFT'],
              basis: CorrelationBasis.priceHistory,
              coefficient: 0.91,
              observations: 58,
              message: 'Se movieron casi igual en los últimos 58 días.',
            ),
            CorrelationWarning(
              tickers: ['JPM', 'BAC'],
              basis: CorrelationBasis.sector,
              coefficient: null,
              observations: null,
              message: 'Comparten sector (Servicios financieros).',
            ),
          ],
        ),
      ),
    );

    // El chip es lo que separa "lo medimos" de "lo inferimos": sin él las dos advertencias se
    // leerían con la misma fuerza probatoria.
    expect(find.text('MEDIDA'), findsOneWidget);
    expect(find.text('POR SECTOR'), findsOneWidget);
    expect(find.text('ρ +0.91'), findsOneWidget);
  });

  testWidgets(
    'sin advertencias distingue "medimos y no correlacionan" de "no pudimos medir"',
    (tester) async {
      // Son dos afirmaciones opuestas que un simple "sin advertencias" mostraría igual.
      await _pumpSheet(
        tester,
        _FakeAuditRepository(audit: _audit(correlationMeasured: true)),
        scopeKey: const ValueKey('medido'),
      );
      expect(
        find.text('No detectamos activos que se muevan casi igual entre sí.'),
        findsOneWidget,
      );

      await _pumpSheet(
        tester,
        _FakeAuditRepository(audit: _audit(correlationMeasured: false)),
        scopeKey: const ValueKey('sin-medir'),
      );
      expect(
        find.textContaining('la ausencia de advertencias no confirma'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
      'una watchlist vacía explica qué hacer, no muestra una torta vacía',
      (tester) async {
    await _pumpSheet(
      tester,
      _FakeAuditRepository(
        audit: _audit(
          positionCount: 0,
          availability: DataAvailability.unavailable,
          sectorDataAvailable: false,
          degradationReason:
              'Todavía no seguís ningún activo. Agregá al menos dos a tu watchlist.',
        ),
      ),
    );

    expect(
      find.text(
        'Todavía no seguís ningún activo. Agregá al menos dos a tu watchlist.',
      ),
      findsOneWidget,
    );
    expect(find.text('Distribución por sectores'), findsNothing);
  });

  testWidgets('recalcular usa el POST, no el GET cacheado', (tester) async {
    // Es la razón de que el controller no sea un `FutureProvider`: invalidarlo reejecutaría el
    // mismo GET que el backend sirve desde su caché, y el botón no haría nada.
    final repository = _FakeAuditRepository(
      audit: _audit(aiSummary: 'Primera versión.'),
      refreshed: _audit(aiSummary: 'Versión recalculada.'),
    );
    await _pumpSheet(tester, repository);

    expect(repository.getCalls, 1);
    expect(find.text('Primera versión.'), findsOneWidget);

    await tester.tap(find.byTooltip('Recalcular la auditoría'));
    await tester.pumpAndSettle();

    expect(repository.refreshCalls, 1);
    expect(repository.getCalls, 1);
    expect(find.text('Versión recalculada.'), findsOneWidget);
  });

  testWidgets('un fallo de red ofrece reintentar', (tester) async {
    await _pumpSheet(
      tester,
      _FakeAuditRepository(audit: _audit(), failGet: true),
    );

    expect(find.text('Reintentar'), findsOneWidget);
  });

  testWidgets('avisa cuando la auditoría viene de la caché del backend', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      _FakeAuditRepository(audit: _audit(servedFromCache: true)),
    );

    expect(find.text('Servida desde la caché del backend'), findsOneWidget);
  });

  // --- Color de sector ----------------------------------------------------------------------

  test('el color de un sector no depende de la cartera que se esté dibujando',
      () {
    // Se indexa por la posición del sector en su enum, no por su posición en la lista: si no,
    // Tecnología cambiaría de color al entrar o salir otro sector, y comparar dos auditorías de un
    // vistazo dejaría de ser posible.
    expect(sectorColor(PortfolioSector.tecnologia),
        sectorColor(PortfolioSector.tecnologia));
    expect(
      sectorColor(PortfolioSector.tecnologia),
      isNot(sectorColor(PortfolioSector.salud)),
    );
  });

  test('sin clasificar va en gris, fuera de la paleta de categorías', () {
    // No es un sector más: es la ausencia de uno, y darle un color propio lo haría pasar por una
    // categoría real.
    expect(sectorColor(PortfolioSector.sinClasificar), AppTheme.textMuted);
    expect(
      AppTheme.categoricalPalette.contains(AppTheme.textMuted),
      isFalse,
    );
  });

  test('la paleta categórica no usa el verde ni el rojo de dirección', () {
    // En esta app verde y rojo significan "sube" y "baja": un sector pintado de verde afirmaría
    // algo que un gráfico de distribución no dice.
    expect(AppTheme.categoricalPalette, isNot(contains(AppTheme.bullish)));
    expect(AppTheme.categoricalPalette, isNot(contains(AppTheme.bearish)));
  });
}
