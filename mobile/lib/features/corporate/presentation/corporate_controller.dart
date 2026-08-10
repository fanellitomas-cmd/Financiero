import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../data/corporate_models.dart';

/// Estado del Hub Corporativo: qué rango mira el calendario, qué símbolo mira el histórico y la
/// biblioteca, y qué filtros tiene puesto el feed de noticias.
///
/// Los cuatro providers de datos son `family` sobre un objeto de consulta inmutable en vez de leer
/// el filtro adentro. Eso da dos cosas que la pantalla necesita: Riverpod cachea por combinación
/// (volver a una pestaña muestra lo anterior al instante en vez de un spinner) y el backend, que ya
/// cachea las respuestas, no recibe un request por rebuild.
///
/// **Ninguno de los cuatro trata la degradación como error.** El backend responde 200 con
/// `availability` + motivo cuando falta una credencial o un proveedor no contesta, así que
/// `AsyncError` acá significa exclusivamente un problema de transporte o de sesión — y la UI lo
/// muestra distinto de una vista degradada, que es un dato válido.

// --- Calendario ----------------------------------------------------------------------------------

/// Ventana del calendario, en días desde hoy.
///
/// Es un conjunto cerrado de opciones y no un `DateRangePicker` libre: el backend topea el rango en
/// 92 días, y ofrecer un selector que permita pedir cinco años para después recortarlos en silencio
/// haría que la pantalla muestre un rango distinto del que el usuario eligió.
enum CalendarWindow { week, twoWeeks, month, quarter }

int calendarWindowDays(CalendarWindow window) => switch (window) {
      CalendarWindow.week => 7,
      CalendarWindow.twoWeeks => 14,
      CalendarWindow.month => 30,
      CalendarWindow.quarter => 90,
    };

String calendarWindowLabel(CalendarWindow window) => switch (window) {
      CalendarWindow.week => '7 días',
      CalendarWindow.twoWeeks => '14 días',
      CalendarWindow.month => '30 días',
      CalendarWindow.quarter => '90 días',
    };

@immutable
class CalendarQuery {
  const CalendarQuery({
    required this.from,
    this.window = CalendarWindow.week,
    this.ticker,
    this.sector,
  });

  /// El día de inicio, sin hora.
  ///
  /// Se guarda en el estado en vez de calcularse dentro del provider a propósito: si el provider
  /// llamara a `DateTime.now()`, la clave del `family` cambiaría cada milisegundo y la caché no
  /// existiría.
  final DateTime from;

  final CalendarWindow window;

  /// Filtro por símbolo. Gana sobre [sector] del lado del backend — son dos preguntas distintas y su
  /// intersección casi siempre es una fila o ninguna.
  final String? ticker;

  final String? sector;

  DateTime get to => from.add(Duration(days: calendarWindowDays(window)));

  CalendarQuery copyWith({
    DateTime? from,
    CalendarWindow? window,
    bool clearTicker = false,
    String? ticker,
    bool clearSector = false,
    String? sector,
  }) =>
      CalendarQuery(
        from: from ?? this.from,
        window: window ?? this.window,
        ticker: clearTicker ? null : (ticker ?? this.ticker),
        sector: clearSector ? null : (sector ?? this.sector),
      );

  // Igualdad estructural porque este objeto es la clave de un `family`: sin esto, cada rebuild
  // construiría una consulta nueva y distinta y el provider volvería a pedir el calendario.
  @override
  bool operator ==(Object other) =>
      other is CalendarQuery &&
      other.from == from &&
      other.window == window &&
      other.ticker == ticker &&
      other.sector == sector;

  @override
  int get hashCode => Object.hash(from, window, ticker, sector);
}

/// El día de hoy sin hora, para anclar el estado inicial del calendario.
DateTime todayOnly({DateTime? now}) {
  final value = (now ?? DateTime.now()).toLocal();
  return DateTime(value.year, value.month, value.day);
}

class CalendarQueryController extends StateNotifier<CalendarQuery> {
  CalendarQueryController({DateTime? now})
      : super(CalendarQuery(from: todayOnly(now: now)));

  void setWindow(CalendarWindow window) =>
      state = state.copyWith(window: window);

  void setTicker(String? raw) {
    final trimmed = raw?.trim().toUpperCase();
    state = (trimmed == null || trimmed.isEmpty)
        ? state.copyWith(clearTicker: true)
        : state.copyWith(ticker: trimmed);
  }

  /// El sector y el símbolo no se acumulan en la UI: el backend le da prioridad al símbolo, así que
  /// dejar los dos puestos mostraría un chip de sector que no está filtrando nada.
  void setSector(String? sector) {
    final trimmed = sector?.trim();
    state = (trimmed == null || trimmed.isEmpty)
        ? state.copyWith(clearSector: true)
        : state.copyWith(sector: trimmed, clearTicker: true);
  }

  /// Corre la ventana hacia adelante o hacia atrás por su propio tamaño.
  void shift({required bool forward}) {
    final days = calendarWindowDays(state.window);
    state = state.copyWith(
      from: state.from.add(Duration(days: forward ? days : -days)),
    );
  }

  void reset({DateTime? now}) =>
      state = CalendarQuery(from: todayOnly(now: now));
}

final calendarQueryProvider =
    StateNotifierProvider<CalendarQueryController, CalendarQuery>(
  (ref) => CalendarQueryController(),
);

final earningsCalendarProvider = FutureProvider.autoDispose
    .family<EarningsCalendar, CalendarQuery>((ref, query) {
  return ref.watch(corporateRepositoryProvider).earningsCalendar(
        from: query.from,
        to: query.to,
        ticker: query.ticker,
        sector: query.sector,
      );
});

/// El calendario del filtro activo.
final activeEarningsCalendarProvider =
    Provider.autoDispose<AsyncValue<EarningsCalendar>>((ref) {
  return ref.watch(earningsCalendarProvider(ref.watch(calendarQueryProvider)));
});

// --- Histórico y biblioteca ----------------------------------------------------------------------

/// El símbolo que miran las pestañas de histórico y de reportes.
///
/// Es un estado compartido por las dos y no uno por pestaña: quien acaba de ver que NVDA superó
/// cuatro trimestres seguidos y pasa a los reportes está siguiendo la misma pregunta sobre la misma
/// empresa, y hacerle tipear el símbolo otra vez rompe ese hilo.
final corporateTickerProvider = StateProvider<String?>((ref) => null);

@immutable
class HistoryQuery {
  const HistoryQuery({required this.ticker, this.limit = 8});

  final String ticker;
  final int limit;

  @override
  bool operator ==(Object other) =>
      other is HistoryQuery && other.ticker == ticker && other.limit == limit;

  @override
  int get hashCode => Object.hash(ticker, limit);
}

final earningsHistoryProvider =
    FutureProvider.autoDispose.family<EarningsHistory, HistoryQuery>(
  (ref, query) => ref
      .watch(corporateRepositoryProvider)
      .earningsHistory(query.ticker, limit: query.limit),
);

@immutable
class FilingsQuery {
  const FilingsQuery({
    required this.ticker,
    this.limit = 10,
    this.summarize = false,
  });

  final String ticker;
  final int limit;

  /// `summarize` es parte de la CLAVE de la caché, no un parámetro que se ignore: pedir la síntesis
  /// tiene que volver a llamar al backend aunque la lista ya esté cacheada, y volver a la vista sin
  /// síntesis no tiene que gastar la llamada al modelo de nuevo.
  final bool summarize;

  FilingsQuery copyWith({int? limit, bool? summarize}) => FilingsQuery(
        ticker: ticker,
        limit: limit ?? this.limit,
        summarize: summarize ?? this.summarize,
      );

  @override
  bool operator ==(Object other) =>
      other is FilingsQuery &&
      other.ticker == ticker &&
      other.limit == limit &&
      other.summarize == summarize;

  @override
  int get hashCode => Object.hash(ticker, limit, summarize);
}

final filingsProvider =
    FutureProvider.autoDispose.family<FilingsResponse, FilingsQuery>(
  (ref, query) => ref.watch(corporateRepositoryProvider).filings(
        query.ticker,
        limit: query.limit,
        summarize: query.summarize,
      ),
);

/// Si la biblioteca del símbolo actual pide la síntesis de IA.
///
/// Vive fuera de la pantalla porque tiene que sobrevivir a un cambio de pestaña: prender la síntesis,
/// ir al calendario y volver no debería apagarla ni, peor, volver a gastar la llamada al modelo.
final filingsSummarizeProvider = StateProvider<bool>((ref) => false);

// --- Noticias ------------------------------------------------------------------------------------

@immutable
class NewsQuery {
  const NewsQuery({
    this.ticker,
    this.category,
    this.sentiment,
    this.limit = 20,
  });

  final String? ticker;
  final NewsCategory? category;
  final NewsSentiment? sentiment;
  final int limit;

  NewsQuery copyWith({
    bool clearTicker = false,
    String? ticker,
    bool clearCategory = false,
    NewsCategory? category,
    bool clearSentiment = false,
    NewsSentiment? sentiment,
    int? limit,
  }) =>
      NewsQuery(
        ticker: clearTicker ? null : (ticker ?? this.ticker),
        category: clearCategory ? null : (category ?? this.category),
        sentiment: clearSentiment ? null : (sentiment ?? this.sentiment),
        limit: limit ?? this.limit,
      );

  bool get hasFilters =>
      ticker != null || category != null || sentiment != null;

  @override
  bool operator ==(Object other) =>
      other is NewsQuery &&
      other.ticker == ticker &&
      other.category == category &&
      other.sentiment == sentiment &&
      other.limit == limit;

  @override
  int get hashCode => Object.hash(ticker, category, sentiment, limit);
}

class NewsQueryController extends StateNotifier<NewsQuery> {
  NewsQueryController() : super(const NewsQuery());

  void setTicker(String? raw) {
    final trimmed = raw?.trim().toUpperCase();
    state = (trimmed == null || trimmed.isEmpty)
        ? state.copyWith(clearTicker: true)
        : state.copyWith(ticker: trimmed);
  }

  /// Toca la categoría: si ya estaba puesta, la saca. Un chip de filtro que solo se puede poner
  /// obliga a buscar dónde se saca.
  void toggleCategory(NewsCategory category) {
    state = state.category == category
        ? state.copyWith(clearCategory: true)
        : state.copyWith(category: category);
  }

  void toggleSentiment(NewsSentiment sentiment) {
    state = state.sentiment == sentiment
        ? state.copyWith(clearSentiment: true)
        : state.copyWith(sentiment: sentiment);
  }

  void clearFilters() => state = NewsQuery(limit: state.limit);
}

final newsQueryProvider =
    StateNotifierProvider<NewsQueryController, NewsQuery>(
  (ref) => NewsQueryController(),
);

final corporateNewsProvider =
    FutureProvider.autoDispose.family<CorporateNewsFeed, NewsQuery>(
  (ref, query) => ref.watch(corporateRepositoryProvider).news(
        ticker: query.ticker,
        category: query.category,
        sentiment: query.sentiment,
        limit: query.limit,
      ),
);

/// El feed con los filtros que están activos ahora.
final activeCorporateNewsProvider =
    Provider.autoDispose<AsyncValue<CorporateNewsFeed>>((ref) {
  return ref.watch(corporateNewsProvider(ref.watch(newsQueryProvider)));
});

// --- Accesos de la Ficha del activo --------------------------------------------------------------

/// El próximo balance de un símbolo, para el acceso rápido de la Ficha.
///
/// Se mira una ventana de 90 días desde hoy: los balances son trimestrales, así que una ventana más
/// corta devolvería "no hay balances" durante la mayor parte del año, que se lee como un dato y no
/// como el límite de la consulta.
///
/// El anclaje del día se hace con [todayOnly] por la misma razón de siempre: `DateTime.now()` como
/// parte de la clave del `family` haría que la caché no exista.
final nextEarningsProvider =
    FutureProvider.autoDispose.family<EarningsEvent?, String>((ref, ticker) async {
  final calendar = await ref.watch(
    earningsCalendarProvider(
      CalendarQuery(
        from: todayOnly(),
        window: CalendarWindow.quarter,
        ticker: ticker,
      ),
    ).future,
  );
  return calendar.events.isEmpty ? null : calendar.events.first;
});

/// Las noticias de un símbolo, para el acceso rápido de la Ficha. Reusa el provider del feed con el
/// filtro por ticker, así el Hub y la Ficha comparten la respuesta cacheada.
final tickerNewsProvider =
    Provider.autoDispose.family<AsyncValue<CorporateNewsFeed>, String>(
  (ref, ticker) =>
      ref.watch(corporateNewsProvider(NewsQuery(ticker: ticker, limit: 10))),
);
