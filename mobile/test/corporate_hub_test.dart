import 'package:financiero_app/core/providers.dart';
import 'package:financiero_app/core/theme/app_theme.dart';
import 'package:financiero_app/core/widgets/degradation_banner.dart';
import 'package:financiero_app/features/corporate/data/corporate_formatting.dart';
import 'package:financiero_app/features/corporate/data/corporate_models.dart';
import 'package:financiero_app/features/corporate/data/corporate_note_snippet.dart';
import 'package:financiero_app/features/corporate/data/corporate_repository.dart';
import 'package:financiero_app/features/corporate/presentation/corporate_controller.dart';
import 'package:financiero_app/features/corporate/widgets/corporate_badges.dart';
import 'package:financiero_app/features/corporate/widgets/corporate_news_tab.dart';
import 'package:financiero_app/features/corporate/widgets/earnings_calendar_tab.dart';
import 'package:financiero_app/features/corporate/widgets/earnings_history_tab.dart';
import 'package:financiero_app/features/corporate/widgets/filings_tab.dart';
import 'package:financiero_app/features/corporate/widgets/save_to_lab_sheet.dart';
import 'package:financiero_app/features/corporate/widgets/surprise_chart.dart';
import 'package:financiero_app/features/corporate/widgets/ticker_corporate_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests del Hub Corporativo (`/api/v1/corporate/*`) en el cliente.
///
/// Lo que este módulo promete y que es fácil de romper sin darse cuenta:
///
///   1. **Un porcentaje de sorpresa ausente NO es un cero.** El backend lo omite cuando la base
///      estimada es demasiado chica para que el cociente signifique algo. Si la UI lo pintara como
///      `0,0%`, estaría afirmando "reportó exactamente lo esperado" sobre un dato que no existe.
///   2. **La tasa de aciertos viaja con su denominador.** Los trimestres sin estimación previa no
///      entran; un "75%" solo esconde que la muestra puede ser de cuatro trimestres.
///   3. **La categoría y el sentimiento de una noticia declaran que son heurísticos.** Un titular
///      BAJISTA es una pista derivada de palabras clave, no el veredicto de un analista.
///   4. **Verde y rojo significan dirección**, nunca decoración: una categoría de noticia no puede
///      pintarse con ellos porque se leería como "esta noticia es buena".
///   5. **Lista vacía por degradación ≠ lista vacía porque no hay datos ≠ lista vacía por los
///      filtros.** Las tres se dicen distinto porque se arreglan distinto.
///   6. **Guardar en el Lab AGREGA al final de una nota existente, nunca reemplaza.** El cuerpo
///      actual puede ser la tesis escrita a mano; el recorte del Hub se puede volver a pedir.

// --- Dobles ------------------------------------------------------------------------------------

class _FakeCorporateRepository implements CorporateRepository {
  _FakeCorporateRepository({
    this.calendar,
    this.history,
    this.filingsResponse,
    this.feed,
  });

  EarningsCalendar? calendar;
  EarningsHistory? history;

  // El campo NO se puede llamar `filings`: ese nombre ya lo ocupa el método de la interfaz.
  FilingsResponse? filingsResponse;

  CorporateNewsFeed? feed;
  Object? failure;

  final List<Map<String, Object?>> calendarCalls = [];
  final List<Map<String, Object?>> historyCalls = [];
  final List<Map<String, Object?>> filingsCalls = [];
  final List<Map<String, Object?>> newsCalls = [];

  @override
  Future<EarningsCalendar> earningsCalendar({
    DateTime? from,
    DateTime? to,
    String? ticker,
    String? sector,
  }) async {
    calendarCalls.add({
      'from': from,
      'to': to,
      'ticker': ticker,
      'sector': sector,
    });
    if (failure != null) throw failure!;
    return calendar ?? _calendar();
  }

  @override
  Future<EarningsHistory> earningsHistory(String ticker, {int limit = 8}) async {
    historyCalls.add({'ticker': ticker, 'limit': limit});
    if (failure != null) throw failure!;
    return history ?? _history();
  }

  @override
  Future<FilingsResponse> filings(
    String ticker, {
    int limit = 10,
    bool summarize = false,
  }) async {
    filingsCalls.add({'ticker': ticker, 'limit': limit, 'summarize': summarize});
    if (failure != null) throw failure!;
    return filingsResponse ?? _filings();
  }

  @override
  Future<CorporateNewsFeed> news({
    String? ticker,
    NewsCategory? category,
    NewsSentiment? sentiment,
    int limit = 20,
  }) async {
    newsCalls.add({
      'ticker': ticker,
      'category': category,
      'sentiment': sentiment,
      'limit': limit,
    });
    if (failure != null) throw failure!;
    return feed ?? _feed();
  }
}

// --- Fixtures ----------------------------------------------------------------------------------

Map<String, dynamic> _eventJson({
  String ticker = 'NVDA',
  String date = '2026-08-27',
  String session = 'AMC',
  double? epsEstimated = 1.00,
  double? epsActual,
  double? epsSurprise,
  double? epsSurprisePct,
  double? revenueEstimated = 45000000000,
  double? revenueActual,
  String direction = 'UNKNOWN',
  String status = 'SCHEDULED',
  String? companyName = 'NVIDIA Corporation',
  String? fiscalPeriodEnd = '2026-07-31',
}) =>
    {
      'ticker': ticker,
      'company_name': companyName,
      'event_date': date,
      'session': session,
      'status': status,
      'fiscal_period': null,
      'fiscal_period_end': fiscalPeriodEnd,
      'eps_estimated': epsEstimated,
      'eps_actual': epsActual,
      'eps_surprise': epsSurprise,
      'eps_surprise_pct': epsSurprisePct,
      'revenue_estimated': revenueEstimated,
      'revenue_actual': revenueActual,
      'revenue_surprise': null,
      'revenue_surprise_pct': null,
      'surprise_direction': direction,
    };

EarningsEvent _event({
  String ticker = 'NVDA',
  String date = '2026-08-27',
  double? epsActual,
  double? epsSurprise,
  double? epsSurprisePct,
  String direction = 'UNKNOWN',
  String status = 'SCHEDULED',
  String session = 'AMC',
}) =>
    EarningsEvent.fromJson(_eventJson(
      ticker: ticker,
      date: date,
      epsActual: epsActual,
      epsSurprise: epsSurprise,
      epsSurprisePct: epsSurprisePct,
      direction: direction,
      status: status,
      session: session,
    ));

EarningsCalendar _calendar({
  List<Map<String, dynamic>>? events,
  String availability = 'AVAILABLE',
  String? reason,
  int unclassified = 0,
  bool cached = false,
}) =>
    EarningsCalendar.fromJson({
      'from_date': '2026-08-10',
      'to_date': '2026-08-17',
      'events': events ??
          [
            _eventJson(ticker: 'AAPL', date: '2026-08-11', session: 'BMO'),
            _eventJson(ticker: 'NVDA', date: '2026-08-13'),
          ],
      'availability': availability,
      'degradation_reason': reason,
      'served_from_cache': cached,
      'unclassified_by_sector': unclassified,
    });

EarningsHistory _history({
  List<Map<String, dynamic>>? quarters,
  int beat = 2,
  int miss = 1,
  int inLine = 0,
  int measured = 3,
  double? average = 2.2,
  String availability = 'AVAILABLE',
  String? reason,
}) =>
    EarningsHistory.fromJson({
      'ticker': 'NVDA',
      'quarters': quarters ??
          [
            _eventJson(
              date: '2026-05-28',
              epsActual: 0.96,
              epsSurprise: 0.03,
              epsSurprisePct: 3.2,
              direction: 'BEAT',
              status: 'REPORTED',
            ),
            _eventJson(
              date: '2026-02-26',
              epsActual: 0.89,
              epsSurprise: 0.04,
              epsSurprisePct: 4.7,
              direction: 'BEAT',
              status: 'REPORTED',
            ),
            _eventJson(
              date: '2025-11-19',
              epsActual: 0.74,
              epsSurprise: -0.01,
              epsSurprisePct: -1.3,
              direction: 'MISS',
              status: 'REPORTED',
            ),
            // Sin estimación: no entra en la tasa. Es la fila que hace visible el denominador.
            _eventJson(
              date: '2025-08-27',
              epsEstimated: null,
              epsActual: 0.68,
              direction: 'UNKNOWN',
              status: 'REPORTED',
            ),
          ],
      'beat_count': beat,
      'miss_count': miss,
      'in_line_count': inLine,
      'measured_quarters': measured,
      'average_surprise_pct': average,
      'availability': availability,
      'degradation_reason': reason,
      'served_from_cache': false,
    });

Map<String, dynamic> _filingJson({
  String type = '10-K',
  String? rawType = '10-K',
  String? filedAt = '2026-02-21T16:31:00Z',
  String? summary,
  bool summaryAvailable = false,
  String? url = 'https://sec.example/nvda/10-K',
}) =>
    {
      'ticker': 'NVDA',
      'filing_type': type,
      'filed_at': filedAt,
      'raw_type': rawType,
      'url': url,
      'final_document_url': null,
      'summary': summary,
      'summary_available': summaryAvailable,
    };

FilingsResponse _filings({
  List<Map<String, dynamic>>? filings,
  String availability = 'AVAILABLE',
  String? reason,
  String? summaryReason,
}) =>
    FilingsResponse.fromJson({
      'ticker': 'NVDA',
      'filings': filings ?? [_filingJson()],
      'availability': availability,
      'degradation_reason': reason,
      'summary_degradation_reason': summaryReason,
      'served_from_cache': false,
    });

Map<String, dynamic> _newsJson({
  String refId = 'news-1',
  String title = 'NVDA reporta ingresos récord y revisa guidance al alza',
  String category = 'EARNINGS',
  String sentiment = 'BULLISH',
  String? source = 'reuters.com',
  String? publishedAt = '2026-08-09T20:05:00Z',
  String? summary = 'Ingresos por USD 46.100 millones, +114% YoY.',
  List<String> tickers = const ['NVDA'],
}) =>
    {
      'ref_id': refId,
      'title': title,
      'source': source,
      'published_at': publishedAt,
      'summary': summary,
      'url': 'https://news.example/$refId',
      'category': category,
      'sentiment': sentiment,
      'classification_source': 'KEYWORD',
      'tickers': tickers,
    };

CorporateNewsFeed _feed({
  List<Map<String, dynamic>>? items,
  String availability = 'AVAILABLE',
  String? reason,
  String? appliedTicker,
  String? appliedCategory,
  String? appliedSentiment,
  int? totalBefore,
}) {
  final list = items ?? [_newsJson()];
  return CorporateNewsFeed.fromJson({
    'items': list,
    'availability': availability,
    'degradation_reason': reason,
    'served_from_cache': false,
    'applied_ticker': appliedTicker,
    'applied_category': appliedCategory,
    'applied_sentiment': appliedSentiment,
    'total_before_filters': totalBefore ?? list.length,
  });
}

CorporateNewsItem _newsItem({
  String category = 'EARNINGS',
  String sentiment = 'BULLISH',
  List<String> tickers = const ['NVDA'],
}) =>
    CorporateNewsItem.fromJson(
      _newsJson(category: category, sentiment: sentiment, tickers: tickers),
    );

// --- Harness -----------------------------------------------------------------------------------

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required _FakeCorporateRepository repository,
  List<Override> overrides = const [],
  Size size = const Size(1100, 1900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        corporateRepositoryProvider.overrideWithValue(repository),
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
  // --- Parseo del contrato --------------------------------------------------------------------

  group('Parseo de los modelos', () {
    test('un porcentaje ausente queda en null y no en cero', () {
      final event = EarningsEvent.fromJson(_eventJson(
        epsActual: 0.05,
        epsSurprise: 0.06,
        epsSurprisePct: null,
        direction: 'BEAT',
        status: 'REPORTED',
      ));

      // La diferencia absoluta SÍ existe: "reportó 6 centavos más de lo esperado" es verdad. Lo que
      // no existe es el porcentaje, porque la base era ruido.
      expect(event.epsSurprise, 0.06);
      expect(event.epsSurprisePct, isNull);
      expect(event.surpriseDirection, SurpriseDirection.beat);
    });

    test('un entero del JSON se convierte a double sin explotar', () {
      // Un ingreso de 46.100 millones llega como `int` en Dart, y un cast directo a `double` tira.
      final event = EarningsEvent.fromJson({
        ..._eventJson(),
        'revenue_estimated': 46100000000,
        'eps_estimated': 1,
      });

      expect(event.revenueEstimated, 46100000000.0);
      expect(event.epsEstimated, 1.0);
    });

    test('un enum desconocido degrada ese campo y no tira la respuesta', () {
      final event = EarningsEvent.fromJson({
        ..._eventJson(),
        'session': 'PREMARKET_EXTENDED',
        'surprise_direction': 'SLIGHTLY_BETTER',
      });

      expect(event.session, EarningsSession.unknown);
      expect(event.surpriseDirection, SurpriseDirection.unknown);
      // Lo demás del evento sobrevive: es el punto de parsear con fallback.
      expect(event.ticker, 'NVDA');
    });

    test('el sentimiento desconocido cae en neutral, no en alcista', () {
      // Ante un valor que este cliente no conoce, la lectura prudente no es "esta noticia es buena".
      final item = CorporateNewsItem.fromJson(_newsJson(sentiment: 'VERY_BULLISH'));
      expect(item.sentiment, NewsSentiment.neutral);
    });

    test('la tasa de aciertos usa los trimestres medidos como denominador', () {
      final history = _history();

      // Cuatro trimestres en la lista, tres medidos: el que llegó sin estimación no se puede contar
      // ni como acierto ni como fallo.
      expect(history.quarters.length, 4);
      expect(history.measuredQuarters, 3);
      expect(history.unmeasuredQuarters, 1);
      expect(history.beatRate, closeTo(2 / 3, 0.0001));
    });

    test('sin trimestres medidos la tasa es null y no cero', () {
      final history = _history(beat: 0, miss: 0, measured: 0, average: null);
      expect(history.beatRate, isNull);
    });

    test('el feed distingue vacío por filtros de vacío sin datos', () {
      final filtered = _feed(
        items: const [],
        appliedCategory: 'RUMOR',
        totalBefore: 20,
      );
      expect(filtered.emptiedByFilters, isTrue);

      final genuinelyEmpty = _feed(items: const [], totalBefore: 0);
      expect(genuinelyEmpty.emptiedByFilters, isFalse);
    });

    test('el calendario agrupa por día conservando el orden del backend', () {
      final calendar = _calendar(events: [
        _eventJson(ticker: 'AAPL', date: '2026-08-11'),
        _eventJson(ticker: 'KO', date: '2026-08-11'),
        _eventJson(ticker: 'NVDA', date: '2026-08-13'),
      ]);

      final grouped = calendar.eventsByDay;
      expect(grouped.keys.map((day) => day.day).toList(), [11, 13]);
      expect(
        grouped[DateTime(2026, 8, 11)]!.map((event) => event.ticker).toList(),
        ['AAPL', 'KO'],
      );
    });

    test('el tipo crudo de la SEC se conserva aunque el normalizado sea OTHER', () {
      final filing = SecFiling.fromJson(
        _filingJson(type: 'OTHER', rawType: '10-K/A'),
      );

      // La enmienda de un 10-K no es un 10-K nuevo: perder el sufijo borraría esa diferencia.
      expect(filing.filingType, FilingType.other);
      expect(filing.displayType, '10-K/A');
    });
  });

  // --- Formateo -------------------------------------------------------------------------------

  group('Formateo', () {
    test('un valor ausente se escribe con guion, nunca con cero', () {
      expect(formatEps(null), kMissingValue);
      expect(formatSurprisePct(null), kMissingValue);
      expect(formatRevenue(null), kMissingValue);
      expect(formatRate(null), kMissingValue);
    });

    test('las diferencias llevan signo explícito', () {
      expect(formatEpsDelta(0.07), '+0,07');
      expect(formatEpsDelta(-0.07), '−0,07');
      expect(formatEpsDelta(0), '0,00');
    });

    test('los porcentajes usan un decimal y coma', () {
      // Un decimal: la precisión de un cociente sobre estimaciones de analistas no llega al segundo,
      // y "4,86%" sugiere una exactitud que el dato no tiene.
      expect(formatSurprisePct(4.861111), '+4,9%');
      expect(formatSurprisePct(-1.25), '−1,3%');
    });

    test('los ingresos se abrevian por magnitud', () {
      expect(formatRevenue(46100000000), 'US\$ 46,10 MM');
      expect(formatRevenue(1500000), 'US\$ 2 M');
      expect(formatRevenue(1.2e12), 'US\$ 1,20 B');
    });

    test('los días hasta el balance se dicen en palabras', () {
      final now = DateTime(2026, 8, 10, 15);
      expect(formatDaysUntil(DateTime(2026, 8, 10), now: now), 'hoy');
      expect(formatDaysUntil(DateTime(2026, 8, 11), now: now), 'mañana');
      expect(formatDaysUntil(DateTime(2026, 8, 20), now: now), 'en 10 d');
      expect(formatDaysUntil(DateTime(2026, 8, 3), now: now), 'hace 7 d');
    });

    test('el período fiscal no convierte una fecha de cierre en un trimestre', () {
      // El trimestre que cierra en junio es el Q2 de algunas empresas y el Q3 de otras: etiquetarlo
      // sería inventarle el calendario fiscal a la empresa.
      final event = _event();
      expect(formatFiscalPeriod(event), 'cierre 31/07/2026');
    });

    test('una noticia sin fecha lo dice en vez de parecer reciente', () {
      expect(formatNewsAge(null), 'sin fecha');
    });
  });

  // --- Colores semánticos ---------------------------------------------------------------------

  group('Semántica del color', () {
    test('verde/rojo solo para dirección y sentimiento', () {
      expect(surpriseDirectionColor(SurpriseDirection.beat), AppTheme.bullish);
      expect(surpriseDirectionColor(SurpriseDirection.miss), AppTheme.bearish);
      expect(surpriseDirectionColor(SurpriseDirection.inLine), AppTheme.accent);
      expect(newsSentimentColor(NewsSentiment.bullish), AppTheme.bullish);
      expect(newsSentimentColor(NewsSentiment.bearish), AppTheme.bearish);
    });

    test('ninguna categoría de noticia usa verde ni rojo', () {
      // Una categoría pintada de verde se leería como "esta noticia es buena", que es una afirmación
      // que un heurístico de palabras clave no hace.
      for (final category in NewsCategory.values) {
        expect(
          newsCategoryColor(category),
          isNot(anyOf(AppTheme.bullish, AppTheme.bearish)),
          reason: 'La categoría ${newsCategoryLabel(category)} no puede usar '
              'los colores de dirección de mercado.',
        );
      }
    });

    test('el color de una categoría no depende de qué otras estén visibles', () {
      // Se indexa por la posición en el enum: si se indexara por la lista que se dibuja, filtrar el
      // feed le cambiaría el color a las categorías que quedan.
      expect(newsCategoryColor(NewsCategory.rumor),
          AppTheme.categorical(NewsCategory.rumor.index));
      expect(newsCategoryColor(NewsCategory.market),
          AppTheme.categorical(NewsCategory.market.index));
    });
  });

  // --- Estado y consultas ---------------------------------------------------------------------

  group('CalendarQuery', () {
    test('igualdad estructural: dos consultas iguales son la misma clave', () {
      final from = DateTime(2026, 8, 10);
      expect(
        CalendarQuery(from: from, ticker: 'NVDA'),
        CalendarQuery(from: from, ticker: 'NVDA'),
      );
      expect(
        CalendarQuery(from: from).hashCode,
        CalendarQuery(from: from).hashCode,
      );
    });

    test('la ventana define el fin del rango', () {
      final query = CalendarQuery(
        from: DateTime(2026, 8, 10),
        window: CalendarWindow.month,
      );
      expect(query.to, DateTime(2026, 9, 9));
    });

    test('elegir un sector borra el símbolo', () {
      // El backend le da prioridad al símbolo: dejar los dos puestos mostraría un chip de sector que
      // no está filtrando nada.
      final controller = CalendarQueryController(now: DateTime(2026, 8, 10));
      controller.setTicker('nvda');
      expect(controller.state.ticker, 'NVDA');

      controller.setSector('Tecnología');
      expect(controller.state.sector, 'Tecnología');
      expect(controller.state.ticker, isNull);
    });

    test('la ventana se corre por su propio tamaño', () {
      final controller = CalendarQueryController(now: DateTime(2026, 8, 10));
      controller.setWindow(CalendarWindow.week);
      controller.shift(forward: true);
      expect(controller.state.from, DateTime(2026, 8, 17));
      controller.shift(forward: false);
      expect(controller.state.from, DateTime(2026, 8, 10));
    });
  });

  group('NewsQuery', () {
    test('tocar dos veces la misma categoría la saca', () {
      final controller = NewsQueryController();
      controller.toggleCategory(NewsCategory.rumor);
      expect(controller.state.category, NewsCategory.rumor);
      controller.toggleCategory(NewsCategory.rumor);
      expect(controller.state.category, isNull);
    });

    test('los filtros se combinan y se limpian juntos', () {
      final controller = NewsQueryController();
      controller.setTicker('nvda');
      controller.toggleCategory(NewsCategory.regulatory);
      controller.toggleSentiment(NewsSentiment.bearish);
      expect(controller.state.hasFilters, isTrue);

      controller.clearFilters();
      expect(controller.state.hasFilters, isFalse);
    });
  });

  group('FilingsQuery', () {
    test('summarize es parte de la clave de la caché', () {
      // Pedir la síntesis tiene que volver a llamar al backend aunque la lista ya esté cacheada.
      const withoutSummary = FilingsQuery(ticker: 'NVDA');
      const withSummary = FilingsQuery(ticker: 'NVDA', summarize: true);
      expect(withoutSummary, isNot(withSummary));
    });
  });

  // --- Repositorio ----------------------------------------------------------------------------

  group('Serialización de los filtros', () {
    test('los enums viajan en el vocabulario del backend', () {
      // `.name` daría camelCase y el backend responde 422: los helpers son lo que evita eso.
      expect(newsCategoryToWire(NewsCategory.regulatory), 'REGULATORY');
      expect(newsSentimentToWire(NewsSentiment.bearish), 'BEARISH');
    });
  });

  // --- Calendario -----------------------------------------------------------------------------

  group('Pestaña Calendario', () {
    testWidgets('agrupa los balances por día con su símbolo y sesión',
        (tester) async {
      final repository = _FakeCorporateRepository();
      await _pump(tester, const EarningsCalendarTab(), repository: repository);

      expect(find.text('AAPL'), findsOneWidget);
      expect(find.text('NVDA'), findsOneWidget);
      expect(find.text('BMO'), findsOneWidget);
      expect(find.text('AMC'), findsOneWidget);
      // Dos días distintos => dos encabezados de grupo.
      expect(find.textContaining('11/08'), findsOneWidget);
      expect(find.textContaining('13/08'), findsOneWidget);
    });

    testWidgets('muestra el rango efectivo que devolvió el backend',
        (tester) async {
      // El backend aplica su propio tope: mostrar el rango pedido dejaría el encabezado mintiendo
      // sobre lo que hay abajo.
      final repository = _FakeCorporateRepository();
      await _pump(tester, const EarningsCalendarTab(), repository: repository);

      expect(find.text('10/08/2026 — 17/08/2026'), findsOneWidget);
    });

    testWidgets('un balance programado no muestra columna de reportado',
        (tester) async {
      final repository = _FakeCorporateRepository();
      await _pump(tester, const EarningsCalendarTab(), repository: repository);

      expect(find.text('EPS est.'), findsNWidgets(2));
      // Una columna vacía en cada fila sugeriría que falta un dato que todavía no existe.
      expect(find.text('EPS rep.'), findsNothing);
    });

    testWidgets('un balance reportado muestra el estimado, el reportado y la sorpresa',
        (tester) async {
      final repository = _FakeCorporateRepository(
        calendar: _calendar(events: [
          _eventJson(
            epsActual: 1.25,
            epsSurprise: 0.25,
            epsSurprisePct: 25,
            direction: 'BEAT',
            status: 'REPORTED',
          ),
        ]),
      );
      await _pump(tester, const EarningsCalendarTab(), repository: repository);

      expect(find.text('EPS rep.'), findsOneWidget);
      expect(find.text('1,25'), findsOneWidget);
      expect(find.text('+0,25'), findsOneWidget);
      expect(find.text('BEAT +25,0%'), findsOneWidget);
    });

    testWidgets('un BEAT sin porcentaje calculable muestra la etiqueta sin número',
        (tester) async {
      final repository = _FakeCorporateRepository(
        calendar: _calendar(events: [
          _eventJson(
            epsActual: 0.05,
            epsSurprise: 0.06,
            epsSurprisePct: null,
            direction: 'BEAT',
            status: 'REPORTED',
          ),
        ]),
      );
      await _pump(tester, const EarningsCalendarTab(), repository: repository);

      // Ni "BEAT 0,0%" ni un porcentaje inventado: la etiqueta sola.
      expect(find.text('BEAT'), findsOneWidget);
      expect(find.textContaining('0,0%'), findsNothing);
    });

    testWidgets('una degradación se avisa y el vacío se explica distinto',
        (tester) async {
      final repository = _FakeCorporateRepository(
        calendar: _calendar(
          events: const [],
          availability: 'UNAVAILABLE',
          reason: 'El proveedor no respondió.',
        ),
      );
      await _pump(tester, const EarningsCalendarTab(), repository: repository);

      expect(find.byType(DegradationBanner), findsOneWidget);
      expect(find.text('El proveedor no respondió.'), findsOneWidget);
      expect(find.textContaining('El aviso de arriba dice por qué'), findsOneWidget);
    });

    testWidgets('un calendario vacío sin degradar invita a ampliar el rango',
        (tester) async {
      final repository = _FakeCorporateRepository(
        calendar: _calendar(events: const []),
      );
      await _pump(tester, const EarningsCalendarTab(), repository: repository);

      // "No reporta nadie" y "no se pudo traer" se dicen distinto porque se arreglan distinto.
      expect(find.byType(DegradationBanner), findsNothing);
      expect(
        find.textContaining('Ningún balance programado en esta ventana'),
        findsOneWidget,
      );
    });

    testWidgets('los excluidos por el filtro de sector se informan', (tester) async {
      final repository = _FakeCorporateRepository(
        calendar: _calendar(unclassified: 3),
      );
      await _pump(tester, const EarningsCalendarTab(), repository: repository);

      // Sin esto, una lista corta se lee como "esta semana no reporta nadie más de este sector".
      expect(find.textContaining('3 balance(s) quedaron afuera'), findsOneWidget);
    });

    testWidgets('cambiar la ventana vuelve a pedir el calendario', (tester) async {
      final repository = _FakeCorporateRepository();
      await _pump(tester, const EarningsCalendarTab(), repository: repository);
      expect(repository.calendarCalls.length, 1);

      await tester.tap(find.text('30 días'));
      await tester.pumpAndSettle();

      expect(repository.calendarCalls.length, 2);
      final last = repository.calendarCalls.last;
      expect(
        (last['to']! as DateTime).difference(last['from']! as DateTime).inDays,
        30,
      );
    });

    testWidgets('elegir un sector lo manda al backend y saca el símbolo',
        (tester) async {
      final repository = _FakeCorporateRepository();
      await _pump(tester, const EarningsCalendarTab(), repository: repository);

      // `ensureVisible` porque la fila de sectores scrollea en horizontal: un chip fuera del
      // viewport recibe el tap en una coordenada que no le corresponde.
      final chip = find.widgetWithText(FilterChip, 'Energía');
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();

      expect(repository.calendarCalls.last['sector'], 'Energía');
      expect(repository.calendarCalls.last['ticker'], isNull);
    });

    testWidgets('un error de transporte se muestra con reintento', (tester) async {
      final repository = _FakeCorporateRepository()..failure = Exception('sin red');
      await _pump(tester, const EarningsCalendarTab(), repository: repository);

      expect(find.text('Reintentar'), findsOneWidget);
    });
  });

  // --- Histórico ------------------------------------------------------------------------------

  group('Pestaña Histórico', () {
    testWidgets('sin símbolo elegido explica qué hacer', (tester) async {
      final repository = _FakeCorporateRepository();
      await _pump(tester, const EarningsHistoryTab(), repository: repository);

      expect(find.textContaining('Elegí un símbolo arriba'), findsOneWidget);
      // No se pide nada al backend sin símbolo: no habría a quién preguntarle.
      expect(repository.historyCalls, isEmpty);
    });

    testWidgets('la tasa de aciertos viaja con su denominador', (tester) async {
      final repository = _FakeCorporateRepository();
      await _pump(
        tester,
        const EarningsHistoryTab(),
        repository: repository,
        overrides: [
          corporateTickerProvider.overrideWith((ref) => 'NVDA'),
        ],
      );

      // "2/3" y no "67%": el porcentaje solo esconde que la muestra son tres trimestres.
      expect(find.text('2/3'), findsOneWidget);
      expect(find.text('67% de aciertos'), findsOneWidget);
    });

    testWidgets('explica por qué la lista tiene más filas que el denominador',
        (tester) async {
      final repository = _FakeCorporateRepository();
      await _pump(
        tester,
        const EarningsHistoryTab(),
        repository: repository,
        overrides: [corporateTickerProvider.overrideWith((ref) => 'NVDA')],
      );

      expect(
        find.textContaining('llegaron sin estimación previa'),
        findsOneWidget,
      );
    });

    testWidgets('sin promedio calculable lo dice en vez de mostrar cero',
        (tester) async {
      final repository = _FakeCorporateRepository(history: _history(average: null));
      await _pump(
        tester,
        const EarningsHistoryTab(),
        repository: repository,
        overrides: [corporateTickerProvider.overrideWith((ref) => 'NVDA')],
      );

      expect(find.text(kMissingValue), findsWidgets);
      expect(
        find.text('ningún trimestre con % calculable'),
        findsOneWidget,
      );
    });

    testWidgets('el gráfico dice cuántos trimestres no pudo dibujar', (tester) async {
      final repository = _FakeCorporateRepository();
      await _pump(
        tester,
        const EarningsHistoryTab(),
        repository: repository,
        overrides: [corporateTickerProvider.overrideWith((ref) => 'NVDA')],
      );

      expect(find.byType(SurpriseChart), findsOneWidget);
      // El trimestre sin estimación no tiene barra: dibujarlo con altura cero lo mostraría como
      // "reportó exactamente lo esperado".
      expect(find.text('1 sin % calculable'), findsOneWidget);
    });

    testWidgets('sin ningún porcentaje calculable el gráfico lo explica',
        (tester) async {
      final repository = _FakeCorporateRepository(
        history: _history(
          quarters: [
            _eventJson(
              epsEstimated: null,
              epsActual: 0.68,
              status: 'REPORTED',
            ),
          ],
          beat: 0,
          miss: 0,
          measured: 0,
          average: null,
        ),
      );
      await _pump(
        tester,
        const EarningsHistoryTab(),
        repository: repository,
        overrides: [corporateTickerProvider.overrideWith((ref) => 'NVDA')],
      );

      expect(
        find.textContaining('Ningún trimestre tiene un porcentaje de sorpresa calculable'),
        findsOneWidget,
      );
    });

    testWidgets('un histórico vacío distingue degradación de falta de datos',
        (tester) async {
      final repository = _FakeCorporateRepository(
        history: _history(
          quarters: const [],
          availability: 'UNAVAILABLE',
          reason: 'El proveedor no respondió.',
        ),
      );
      await _pump(
        tester,
        const EarningsHistoryTab(),
        repository: repository,
        overrides: [corporateTickerProvider.overrideWith((ref) => 'NVDA')],
      );

      expect(find.byType(DegradationBanner), findsOneWidget);
      expect(
        find.textContaining('No se pudo traer el histórico'),
        findsOneWidget,
      );
    });
  });

  // --- Reportes -------------------------------------------------------------------------------

  group('Pestaña Reportes', () {
    testWidgets('lista los reportes con su tipo y qué es cada uno', (tester) async {
      final repository = _FakeCorporateRepository();
      await _pump(
        tester,
        const FilingsTab(),
        repository: repository,
        overrides: [corporateTickerProvider.overrideWith((ref) => 'NVDA')],
      );

      expect(find.text('10-K'), findsOneWidget);
      expect(find.text('21/02/2026'), findsOneWidget);
      // La descripción del tipo se muestra con o sin IA: es información estática y verdadera.
      expect(
        find.textContaining('Informe anual auditado'),
        findsOneWidget,
      );
    });

    testWidgets('la síntesis es opt-in: por defecto no se pide', (tester) async {
      final repository = _FakeCorporateRepository();
      await _pump(
        tester,
        const FilingsTab(),
        repository: repository,
        overrides: [corporateTickerProvider.overrideWith((ref) => 'NVDA')],
      );

      expect(repository.filingsCalls.single['summarize'], isFalse);
    });

    testWidgets('prender el switch pide la síntesis al backend', (tester) async {
      final repository = _FakeCorporateRepository();
      await _pump(
        tester,
        const FilingsTab(),
        repository: repository,
        overrides: [corporateTickerProvider.overrideWith((ref) => 'NVDA')],
      );

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(repository.filingsCalls.last['summarize'], isTrue);
    });

    testWidgets('la síntesis se despliega con su advertencia de procedencia',
        (tester) async {
      final repository = _FakeCorporateRepository(
        filingsResponse: _filings(
          filings: [
            _filingJson(
              summary: 'El 10-K es el informe anual auditado.',
              summaryAvailable: true,
            ),
          ],
        ),
      );
      await _pump(
        tester,
        const FilingsTab(),
        repository: repository,
        overrides: [corporateTickerProvider.overrideWith((ref) => 'NVDA')],
      );

      await tester.tap(find.byTooltip('Ver la síntesis'));
      await tester.pumpAndSettle();

      expect(find.text('El 10-K es el informe anual auditado.'), findsOneWidget);
      // Sin este cartel, un párrafo bien escrito debajo de "10-K" se lee como un resumen de lo que
      // el 10-K dice — y el backend nunca descargó el documento.
      expect(
        find.textContaining('el sistema no descargó el documento'),
        findsOneWidget,
      );
    });

    testWidgets('el fallo de la síntesis no se confunde con falta de reportes',
        (tester) async {
      final repository = _FakeCorporateRepository(
        filingsResponse: _filings(summaryReason: 'No se pudo generar la síntesis.'),
      );
      await _pump(
        tester,
        const FilingsTab(),
        repository: repository,
        overrides: [corporateTickerProvider.overrideWith((ref) => 'NVDA')],
      );

      // La lista llegó perfecta: el aviso es solo de la síntesis, y el reporte sigue en pantalla.
      expect(find.text('No se pudo generar la síntesis.'), findsOneWidget);
      expect(find.text('10-K'), findsOneWidget);
    });

    testWidgets('un reporte sin enlace deshabilita el botón de copiar',
        (tester) async {
      final repository = _FakeCorporateRepository(
        filingsResponse: _filings(filings: [_filingJson(url: null)]),
      );
      await _pump(
        tester,
        const FilingsTab(),
        repository: repository,
        overrides: [corporateTickerProvider.overrideWith((ref) => 'NVDA')],
      );

      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('Este reporte llegó sin enlace del proveedor'),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNull);
    });
  });

  // --- Noticias -------------------------------------------------------------------------------

  group('Pestaña Noticias', () {
    testWidgets('muestra titular, fuente, antigüedad y las dos insignias',
        (tester) async {
      final repository = _FakeCorporateRepository();
      await _pump(tester, const CorporateNewsTab(), repository: repository);

      expect(
        find.text('NVDA reporta ingresos récord y revisa guidance al alza'),
        findsOneWidget,
      );
      expect(find.text('reuters.com'), findsOneWidget);
      expect(find.byType(NewsCategoryBadge), findsOneWidget);
      expect(find.byType(NewsSentimentBadge), findsOneWidget);
    });

    testWidgets('el feed declara que la clasificación es un heurístico',
        (tester) async {
      final repository = _FakeCorporateRepository();
      await _pump(tester, const CorporateNewsTab(), repository: repository);

      // Sin esto, un "BAJISTA" al lado de un titular se lee como el veredicto de un analista.
      expect(
        find.textContaining('derivados de palabras clave del titular'),
        findsOneWidget,
      );
    });

    testWidgets('una noticia sin fuente lo dice en vez de dejar el lugar vacío',
        (tester) async {
      final repository = _FakeCorporateRepository(
        feed: _feed(items: [_newsJson(source: null)]),
      );
      await _pump(tester, const CorporateNewsTab(), repository: repository);

      expect(find.text('fuente desconocida'), findsOneWidget);
    });

    testWidgets('tocar una categoría la manda como filtro al backend',
        (tester) async {
      final repository = _FakeCorporateRepository();
      await _pump(tester, const CorporateNewsTab(), repository: repository);

      await tester.tap(find.widgetWithText(FilterChip, 'RUMOR'));
      await tester.pumpAndSettle();

      expect(repository.newsCalls.last['category'], NewsCategory.rumor);
    });

    testWidgets('con filtros puestos el contador muestra "N de M"', (tester) async {
      final repository = _FakeCorporateRepository(
        feed: _feed(appliedCategory: 'EARNINGS', totalBefore: 20),
      );
      await _pump(tester, const CorporateNewsTab(), repository: repository);

      // "1" solo es ambiguo: puede ser todo lo que hay o el resultado de un filtro que quedó puesto.
      expect(find.text('1 de 20'), findsOneWidget);
    });

    testWidgets('vacío por los filtros ofrece limpiarlos', (tester) async {
      final repository = _FakeCorporateRepository(
        feed: _feed(
          items: const [],
          appliedCategory: 'RUMOR',
          totalBefore: 20,
        ),
      );
      await _pump(tester, const CorporateNewsTab(), repository: repository);

      expect(
        find.textContaining('Ninguna de las 20 noticias del feed pasa los filtros'),
        findsOneWidget,
      );
      expect(find.text('Limpiar los filtros'), findsOneWidget);
    });

    testWidgets('vacío sin filtros no ofrece limpiar nada', (tester) async {
      final repository = _FakeCorporateRepository(
        feed: _feed(items: const [], totalBefore: 0),
      );
      await _pump(tester, const CorporateNewsTab(), repository: repository);

      expect(find.text('No hay noticias recientes para esta búsqueda.'),
          findsOneWidget);
      expect(find.text('Limpiar los filtros'), findsNothing);
    });

    testWidgets('sin credenciales del buscador el feed avisa el motivo',
        (tester) async {
      final repository = _FakeCorporateRepository(
        feed: _feed(
          items: const [],
          availability: 'UNAVAILABLE',
          reason: 'El buscador de noticias no está configurado.',
        ),
      );
      await _pump(tester, const CorporateNewsTab(), repository: repository);

      expect(find.byType(DegradationBanner), findsOneWidget);
      expect(
        find.text('El buscador de noticias no está configurado.'),
        findsOneWidget,
      );
    });
  });

  // --- Bloques Markdown para el Lab -----------------------------------------------------------

  group('Bloques para el Investment Lab', () {
    test('el balance transcribe estimado, reportado y sorpresa', () {
      final markdown = buildEarningsNoteMarkdown(
        _event(
          epsActual: 1.25,
          epsSurprise: 0.25,
          epsSurprisePct: 25,
          direction: 'BEAT',
          status: 'REPORTED',
        ),
        now: DateTime(2026, 8, 10, 15, 30),
      );

      expect(markdown, contains('## $kEarningsSnippetHeading — NVDA'));
      expect(markdown, contains('Guardado desde el Hub Corporativo el 10/08/2026 15:30'));
      expect(markdown, contains('- Estimado: `1,00`'));
      expect(markdown, contains('- Reportado: `1,25`'));
      expect(markdown, contains('+25,0%'));
      expect(markdown, contains('**BEAT**'));
    });

    test('sin porcentaje calculable la nota explica por qué falta', () {
      // Una nota que solo omitiera el número dejaría al lector creyendo que el dato no existía.
      final markdown = buildEarningsNoteMarkdown(
        _event(
          epsActual: 0.05,
          epsSurprise: 0.06,
          epsSurprisePct: null,
          direction: 'BEAT',
          status: 'REPORTED',
        ),
      );

      expect(markdown, contains('+0,06'));
      expect(
        markdown,
        contains('el estimado estaba demasiado cerca de cero'),
      );
    });

    test('el histórico escribe el denominador y no usa tablas', () {
      final markdown = buildEarningsHistoryNoteMarkdown(_history());

      expect(markdown, contains('**2** de 3 trimestres medidos'));
      expect(markdown, contains('(67%)'));
      expect(markdown, contains('llegaron sin estimación previa'));
      // El visor de notas de la app no renderiza tablas: una tabla quedaría como pipes literales.
      expect(markdown, isNot(contains('| --- |')));
    });

    test('la noticia copia la advertencia de procedencia', () {
      final markdown = buildNewsNoteMarkdown(_newsItem());

      expect(markdown, contains('**BALANCES**'));
      expect(markdown, contains('**ALCISTA**'));
      // La advertencia va DENTRO de la nota: la nota es lo que se relee.
      expect(
        markdown,
        contains('derivados de palabras clave del titular'),
      );
    });

    test('el reporte sin síntesis dice que el enlace es la fuente', () {
      final markdown = buildFilingNoteMarkdown(
        SecFiling.fromJson(_filingJson()),
      );

      expect(markdown, contains('https://sec.example/nvda/10-K'));
      expect(markdown, contains('Sin síntesis'));
    });

    test('la síntesis se copia con su límite declarado', () {
      final markdown = buildFilingNoteMarkdown(
        SecFiling.fromJson(_filingJson(
          summary: 'El 10-K es el informe anual auditado.',
          summaryAvailable: true,
        )),
      );

      expect(markdown, contains('El 10-K es el informe anual auditado.'));
      expect(markdown, contains('el sistema no descargó el documento'));
    });

    test('un titular larguísimo se corta antes de que el backend lo rechace', () {
      final draft = newsNoteDraft(
        CorporateNewsItem.fromJson(_newsJson(title: 'a' * 400)),
      );

      expect(draft.title.length, lessThanOrEqualTo(120));
      expect(draft.title, endsWith('…'));
    });

    test('la nota de una noticia de mercado no se atribuye a un símbolo', () {
      // Atribuirle una noticia de mercado a un activo al azar la haría aparecer en la ficha de una
      // empresa que la nota no menciona.
      final draft = newsNoteDraft(_newsItem(tickers: const []));
      expect(draft.ticker, isNull);

      final linked = newsNoteDraft(_newsItem(tickers: const ['NVDA']));
      expect(draft.ticker, isNull);
      expect(linked.normalizedTicker, 'NVDA');
    });

    test('anexar conserva el cuerpo que ya tenía la nota', () {
      const existing = 'Mi tesis escrita a mano.';
      final result = appendCorporateSnippet(existing, 'Bloque nuevo.');

      expect(result, startsWith(existing));
      expect(result, contains('Bloque nuevo.'));
    });

    test('anexar a una nota vacía no deja saltos de línea al principio', () {
      expect(appendCorporateSnippet('   ', 'Bloque.'), 'Bloque.');
    });
  });

  // --- Guardar en el Lab ----------------------------------------------------------------------

  group('SaveToLabButton', () {
    testWidgets('abre la hoja con el título propuesto', (tester) async {
      final repository = _FakeCorporateRepository();
      final event = _event();

      await _pump(
        tester,
        SaveToLabButton(
          heading: 'Balance de NVDA',
          draft: earningsNoteDraft(event),
          snippet: buildEarningsNoteMarkdown(event),
          ticker: 'NVDA',
        ),
        repository: repository,
      );

      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();

      expect(find.text('Guardar en el Lab'), findsOneWidget);
      expect(find.text('Crear una nota nueva'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'NVDA — Balance del 27/08/2026'),
        findsOneWidget,
      );
    });

    testWidgets('la vista previa arranca cerrada y se puede abrir', (tester) async {
      final repository = _FakeCorporateRepository();
      final event = _event();

      await _pump(
        tester,
        SaveToLabButton(
          heading: 'Balance de NVDA',
          draft: earningsNoteDraft(event),
          snippet: buildEarningsNoteMarkdown(event),
          ticker: 'NVDA',
        ),
        repository: repository,
      );

      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();

      expect(find.text('Ver lo que se va a guardar'), findsOneWidget);
      await tester.tap(find.text('Ver lo que se va a guardar'));
      await tester.pumpAndSettle();
      expect(find.text('Ocultar lo que se va a guardar'), findsOneWidget);
    });
  });

  // --- Acceso rápido en la Ficha del activo ---------------------------------------------------

  group('Pestaña Corporativo de la Ficha', () {
    testWidgets('muestra el próximo balance y las noticias del símbolo',
        (tester) async {
      final repository = _FakeCorporateRepository(
        calendar: _calendar(
          events: [_eventJson(date: '2026-08-27')],
        ),
      );
      await _pump(
        tester,
        const TickerCorporateTab(ticker: 'NVDA'),
        repository: repository,
      );

      expect(find.text('Próximo balance'), findsOneWidget);
      expect(find.text('Noticias y rumores'), findsOneWidget);
      expect(find.byType(EarningsEventCard), findsOneWidget);
      expect(find.byType(CorporateNewsCard), findsOneWidget);
    });

    testWidgets('pide el calendario filtrado por el símbolo de la ficha',
        (tester) async {
      final repository = _FakeCorporateRepository();
      await _pump(
        tester,
        const TickerCorporateTab(ticker: 'NVDA'),
        repository: repository,
      );

      expect(repository.calendarCalls.single['ticker'], 'NVDA');
      expect(repository.newsCalls.single['ticker'], 'NVDA');
    });

    testWidgets('sin balance en la ventana dice cuál era la ventana',
        (tester) async {
      // "No hay balance" sin el rango se leería como "esta empresa no reporta".
      final repository = _FakeCorporateRepository(
        calendar: _calendar(events: const []),
      );
      await _pump(
        tester,
        const TickerCorporateTab(ticker: 'NVDA'),
        repository: repository,
      );

      expect(
        find.text('Sin balances programados en los próximos 90 días.'),
        findsOneWidget,
      );
    });

    testWidgets('una mitad degradada no vacía la otra', (tester) async {
      final repository = _FakeCorporateRepository(
        feed: _feed(
          items: const [],
          availability: 'UNAVAILABLE',
          reason: 'El buscador de noticias no está configurado.',
        ),
        calendar: _calendar(events: [_eventJson()]),
      );
      await _pump(
        tester,
        const TickerCorporateTab(ticker: 'NVDA'),
        repository: repository,
      );

      // El balance sigue en pantalla aunque las noticias no estén disponibles: son dos fuentes
      // independientes y por eso cada una avisa por su cuenta.
      expect(find.byType(EarningsEventCard), findsOneWidget);
      expect(find.byType(DegradationBanner), findsOneWidget);
    });
  });

  // --- Insignias ------------------------------------------------------------------------------

  group('Insignias', () {
    testWidgets('la sesión desconocida se dice, no se deja en blanco',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: SessionBadge(session: EarningsSession.unknown),
          ),
        ),
      );

      expect(find.text('SIN HORA'), findsOneWidget);
    });

    testWidgets('una dirección desconocida no dibuja insignia', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: SurpriseBadge(direction: SurpriseDirection.unknown),
          ),
        ),
      );

      // Una columna de "SIN DATO" gris en cada balance programado sería ruido compitiendo con los
      // estimados, que es lo que en esas filas sí se puede leer.
      expect(find.byType(CorporateBadge), findsNothing);
    });

    testWidgets('el sentimiento explica de dónde sale en su tooltip',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: NewsSentimentBadge(
              sentiment: NewsSentiment.bearish,
              source: ClassificationSource.keyword,
            ),
          ),
        ),
      );

      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, contains('palabras clave'));
    });
  });
}
