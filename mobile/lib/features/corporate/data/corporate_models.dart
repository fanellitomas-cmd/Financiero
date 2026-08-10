/// Modelos de `/api/v1/corporate/*` — el Corporate Intelligence Hub.
///
/// Espejan `app/schemas/corporate.py`. Tres reglas del contrato que este archivo tiene que
/// preservar tal cual, porque son las que evitan que la UI afirme cosas que nadie midió:
///
///   1. **Un porcentaje de sorpresa en `null` no es un cero.** El backend lo omite cuando la base
///      estimada es demasiado chica para que el cociente signifique algo. La UI muestra la
///      diferencia absoluta y calla el porcentaje; poner un 0 diría "reportó exactamente lo
///      esperado", que es otra afirmación.
///   2. **La categoría y el sentimiento de una noticia son heurísticos, y viajan con
///      [CorporateNewsItem.classificationSource] para poder decirlo.** Un titular BEARISH es una
///      pista derivada del texto, no el veredicto de un analista.
///   3. **Lista vacía por falta de credenciales ≠ lista vacía porque no hay datos.** Las dos llegan
///      con 200; lo único que las distingue es `availability` + `degradationReason`.
///
/// Mismo criterio de parseo que el resto de la app: **todo enum se parsea con fallback, nunca con
/// `throw`**. Una categoría nueva del lado del servidor tiene que degradar ese ítem, no tirar el
/// feed entero.
library;

import 'package:flutter/foundation.dart';

import '../../../core/data/data_availability.dart';

export '../../../core/data/data_availability.dart'
    show DataAvailability, availabilityFromWire;

// --- Enums ---------------------------------------------------------------------------------------

/// Cuándo reporta la empresa respecto de la rueda: antes de la apertura, después del cierre o
/// durante.
///
/// [EarningsSession.unknown] es un valor frecuente y de primera clase: muchos proveedores no traen
/// el horario para fechas lejanas. Mostrar "BMO" cuando no se sabe haría que alguien planifique una
/// operación para la apertura sobre un dato inventado.
enum EarningsSession { bmo, amc, during, unknown }

EarningsSession earningsSessionFromWire(String? value) => switch (value) {
      'BMO' => EarningsSession.bmo,
      'AMC' => EarningsSession.amc,
      'DURING' => EarningsSession.during,
      _ => EarningsSession.unknown,
    };

/// Etiqueta corta para el badge. `unknown` dice "sin hora" y no queda en blanco: un badge vacío se
/// lee como un error de la app.
String earningsSessionLabel(EarningsSession session) => switch (session) {
      EarningsSession.bmo => 'BMO',
      EarningsSession.amc => 'AMC',
      EarningsSession.during => 'EN RUEDA',
      EarningsSession.unknown => 'SIN HORA',
    };

/// Qué significa la sigla, para el tooltip. BMO/AMC son jerga de terminal: quien no la conoce no
/// puede deducirla, y quien sí la conoce no necesita leerla.
String earningsSessionTooltip(EarningsSession session) => switch (session) {
      EarningsSession.bmo => 'Before Market Open — reporta antes de la apertura.',
      EarningsSession.amc => 'After Market Close — reporta después del cierre.',
      EarningsSession.during => 'Reporta con el mercado abierto.',
      EarningsSession.unknown =>
        'El proveedor todavía no confirmó el horario del reporte.',
    };

/// Si el balance ya se publicó. Lo deriva el backend de la presencia de números reportados y no de
/// la fecha: un balance de ayer sin datos cargados sigue siendo "programado" para el usuario,
/// porque no hay nada que leer.
enum EarningsStatus { scheduled, reported }

EarningsStatus earningsStatusFromWire(String? value) =>
    value == 'REPORTED' ? EarningsStatus.reported : EarningsStatus.scheduled;

/// Si la empresa superó, falló o cumplió la estimación de EPS.
///
/// [SurpriseDirection.unknown] es el estado de un balance todavía no reportado y también el de uno
/// reportado sin estimación previa — en los dos casos no hay contra qué comparar.
enum SurpriseDirection { beat, miss, inLine, unknown }

SurpriseDirection surpriseDirectionFromWire(String? value) => switch (value) {
      'BEAT' => SurpriseDirection.beat,
      'MISS' => SurpriseDirection.miss,
      'IN_LINE' => SurpriseDirection.inLine,
      _ => SurpriseDirection.unknown,
    };

String surpriseDirectionLabel(SurpriseDirection direction) => switch (direction) {
      SurpriseDirection.beat => 'BEAT',
      SurpriseDirection.miss => 'MISS',
      SurpriseDirection.inLine => 'EN LÍNEA',
      SurpriseDirection.unknown => 'SIN DATO',
    };

/// Tipo de reporte ante la SEC. `other` recoge todo lo demás (S-1, DEF 14A…) en vez de esconderlo.
enum FilingType { tenK, tenQ, eightK, other }

FilingType filingTypeFromWire(String? value) => switch (value) {
      '10-K' => FilingType.tenK,
      '10-Q' => FilingType.tenQ,
      '8-K' => FilingType.eightK,
      _ => FilingType.other,
    };

String filingTypeLabel(FilingType type) => switch (type) {
      FilingType.tenK => '10-K',
      FilingType.tenQ => '10-Q',
      FilingType.eightK => '8-K',
      FilingType.other => 'OTRO',
    };

/// Qué es cada tipo de reporte, en una línea. Se muestra SIEMPRE, incluso sin la síntesis de IA:
/// es información estática y verdadera que no depende de que haya credenciales de modelo.
String filingTypeDescription(FilingType type) => switch (type) {
      FilingType.tenK => 'Informe anual auditado: estados contables, riesgos y gestión.',
      FilingType.tenQ => 'Informe trimestral, sin auditar.',
      FilingType.eightK => 'Hecho relevante: algo que la empresa tuvo que informar ya.',
      FilingType.other => 'Otro tipo de presentación ante la SEC.',
    };

/// Qué clase de novedad es. El orden de clasificación lo decide el backend; acá solo se muestra.
enum NewsCategory { rumor, corporate, regulatory, earnings, market }

NewsCategory newsCategoryFromWire(String? value) => switch (value) {
      'RUMOR' => NewsCategory.rumor,
      'CORPORATE' => NewsCategory.corporate,
      'REGULATORY' => NewsCategory.regulatory,
      'EARNINGS' => NewsCategory.earnings,
      _ => NewsCategory.market,
    };

/// El valor que va al query string. Se deriva del enum en vez de escribirse en cada call site: con
/// cinco categorías y tres filtros, un literal mal tipeado devuelve un 422 desde una pantalla.
String newsCategoryToWire(NewsCategory category) => switch (category) {
      NewsCategory.rumor => 'RUMOR',
      NewsCategory.corporate => 'CORPORATE',
      NewsCategory.regulatory => 'REGULATORY',
      NewsCategory.earnings => 'EARNINGS',
      NewsCategory.market => 'MARKET',
    };

String newsCategoryLabel(NewsCategory category) => switch (category) {
      NewsCategory.rumor => 'RUMOR',
      NewsCategory.corporate => 'CORPORATIVO',
      NewsCategory.regulatory => 'REGULATORIO',
      NewsCategory.earnings => 'BALANCES',
      NewsCategory.market => 'MERCADO',
    };

enum NewsSentiment { bullish, bearish, neutral }

/// `neutral` como fallback: ante un valor que este cliente no conoce, la lectura prudente no es
/// "esta noticia es buena".
NewsSentiment newsSentimentFromWire(String? value) => switch (value) {
      'BULLISH' => NewsSentiment.bullish,
      'BEARISH' => NewsSentiment.bearish,
      _ => NewsSentiment.neutral,
    };

String newsSentimentToWire(NewsSentiment sentiment) => switch (sentiment) {
      NewsSentiment.bullish => 'BULLISH',
      NewsSentiment.bearish => 'BEARISH',
      NewsSentiment.neutral => 'NEUTRAL',
    };

String newsSentimentLabel(NewsSentiment sentiment) => switch (sentiment) {
      NewsSentiment.bullish => 'ALCISTA',
      NewsSentiment.bearish => 'BAJISTA',
      NewsSentiment.neutral => 'NEUTRAL',
    };

/// De dónde salen la categoría y el sentimiento de un ítem.
///
/// Hoy el backend solo manda `KEYWORD`, y el enum existe igual: cuando aparezca una clasificación
/// por modelo, esta app va a poder mostrarlas distinto en vez de presentar las dos con el mismo
/// peso. El fallback es `keyword` porque es la más débil de las dos.
enum ClassificationSource { keyword }

ClassificationSource classificationSourceFromWire(String? value) =>
    ClassificationSource.keyword;

/// Cómo se le explica al usuario de dónde viene la etiqueta. Es la pieza que convierte una
/// afirmación en una pista.
String classificationSourceCaption(ClassificationSource source) => switch (source) {
      ClassificationSource.keyword =>
        'Categoría y sentimiento derivados de palabras clave del titular, '
            'no de un análisis del contenido.',
    };

// --- Balances ------------------------------------------------------------------------------------

@immutable
class EarningsEvent {
  const EarningsEvent({
    required this.ticker,
    required this.companyName,
    required this.eventDate,
    required this.session,
    required this.status,
    required this.fiscalPeriod,
    required this.fiscalPeriodEnd,
    required this.epsEstimated,
    required this.epsActual,
    required this.epsSurprise,
    required this.epsSurprisePct,
    required this.revenueEstimated,
    required this.revenueActual,
    required this.revenueSurprise,
    required this.revenueSurprisePct,
    required this.surpriseDirection,
  });

  factory EarningsEvent.fromJson(Map<String, dynamic> json) => EarningsEvent(
        ticker: json['ticker'] as String,
        companyName: json['company_name'] as String?,
        eventDate: DateTime.parse(json['event_date'] as String),
        session: earningsSessionFromWire(json['session'] as String?),
        status: earningsStatusFromWire(json['status'] as String?),
        fiscalPeriod: json['fiscal_period'] as String?,
        fiscalPeriodEnd: _parseDate(json['fiscal_period_end']),
        epsEstimated: _parseDouble(json['eps_estimated']),
        epsActual: _parseDouble(json['eps_actual']),
        epsSurprise: _parseDouble(json['eps_surprise']),
        epsSurprisePct: _parseDouble(json['eps_surprise_pct']),
        revenueEstimated: _parseDouble(json['revenue_estimated']),
        revenueActual: _parseDouble(json['revenue_actual']),
        revenueSurprise: _parseDouble(json['revenue_surprise']),
        revenueSurprisePct: _parseDouble(json['revenue_surprise_pct']),
        surpriseDirection:
            surpriseDirectionFromWire(json['surprise_direction'] as String?),
      );

  final String ticker;
  final String? companyName;

  /// Día del reporte. Es una fecha, no un timestamp: el horario se expresa con [session], que es
  /// todo lo que el proveedor sabe.
  final DateTime eventDate;

  final EarningsSession session;
  final EarningsStatus status;

  /// Período fiscal tal como lo nombra el proveedor ("Q3 2026"), cuando lo nombra.
  final String? fiscalPeriod;

  /// Cierre del trimestre que se reporta. Viaja como fecha y no como etiqueta: el trimestre que
  /// cierra en junio es el Q2 de algunas empresas y el Q3 de otras, y convertirlo sería inventarle
  /// el calendario fiscal a la empresa.
  final DateTime? fiscalPeriodEnd;

  final double? epsEstimated;
  final double? epsActual;

  /// Diferencia absoluta reportado − estimado. Existe siempre que existan los dos.
  final double? epsSurprise;

  /// `null` cuando el estimado estaba demasiado cerca de cero para que un cociente signifique algo.
  /// **No es un 0.**
  final double? epsSurprisePct;

  final double? revenueEstimated;
  final double? revenueActual;
  final double? revenueSurprise;
  final double? revenueSurprisePct;

  final SurpriseDirection surpriseDirection;

  bool get hasActuals => epsActual != null || revenueActual != null;

  /// ¿Hay algo que comparar en EPS? Es lo que decide si la fila muestra "estimado vs. reportado" o
  /// solo el estimado.
  bool get hasEpsComparison => epsEstimated != null && epsActual != null;
}

@immutable
class EarningsCalendar {
  const EarningsCalendar({
    required this.fromDate,
    required this.toDate,
    required this.events,
    required this.availability,
    required this.degradationReason,
    required this.servedFromCache,
    required this.unclassifiedBySector,
  });

  factory EarningsCalendar.fromJson(Map<String, dynamic> json) =>
      EarningsCalendar(
        fromDate: DateTime.parse(json['from_date'] as String),
        toDate: DateTime.parse(json['to_date'] as String),
        events: ((json['events'] as List?) ?? const [])
            .map((item) => EarningsEvent.fromJson(item as Map<String, dynamic>))
            .toList(),
        availability: availabilityFromWire(json['availability'] as String?),
        degradationReason: json['degradation_reason'] as String?,
        servedFromCache: json['served_from_cache'] as bool? ?? false,
        unclassifiedBySector: json['unclassified_by_sector'] as int? ?? 0,
      );

  /// El rango EFECTIVO que resolvió el backend, no el que se pidió: aplica defaults y un tope de 92
  /// días. La UI muestra este, para que pedir cinco años no deje un encabezado mintiendo.
  final DateTime fromDate;
  final DateTime toDate;

  final List<EarningsEvent> events;
  final DataAvailability availability;
  final String? degradationReason;
  final bool servedFromCache;

  /// Cuántos eventos quedaron afuera del filtro por sector por no estar en el catálogo local. Se
  /// muestra: una lista más corta sin explicación se lee como "esta semana no reporta nadie más".
  final int unclassifiedBySector;

  int get total => events.length;

  /// Los eventos agrupados por día, en orden. `LinkedHashMap` por construcción (los `Map` literales
  /// de Dart preservan el orden de inserción), y la lista ya viene ordenada del backend, así que el
  /// agrupado no reordena nada.
  Map<DateTime, List<EarningsEvent>> get eventsByDay {
    final grouped = <DateTime, List<EarningsEvent>>{};
    for (final event in events) {
      final day = DateTime(
        event.eventDate.year,
        event.eventDate.month,
        event.eventDate.day,
      );
      grouped.putIfAbsent(day, () => <EarningsEvent>[]).add(event);
    }
    return grouped;
  }
}

@immutable
class EarningsHistory {
  const EarningsHistory({
    required this.ticker,
    required this.quarters,
    required this.beatCount,
    required this.missCount,
    required this.inLineCount,
    required this.measuredQuarters,
    required this.averageSurprisePct,
    required this.availability,
    required this.degradationReason,
    required this.servedFromCache,
  });

  factory EarningsHistory.fromJson(Map<String, dynamic> json) => EarningsHistory(
        ticker: json['ticker'] as String,
        quarters: ((json['quarters'] as List?) ?? const [])
            .map((item) => EarningsEvent.fromJson(item as Map<String, dynamic>))
            .toList(),
        beatCount: json['beat_count'] as int? ?? 0,
        missCount: json['miss_count'] as int? ?? 0,
        inLineCount: json['in_line_count'] as int? ?? 0,
        measuredQuarters: json['measured_quarters'] as int? ?? 0,
        averageSurprisePct: _parseDouble(json['average_surprise_pct']),
        availability: availabilityFromWire(json['availability'] as String?),
        degradationReason: json['degradation_reason'] as String?,
        servedFromCache: json['served_from_cache'] as bool? ?? false,
      );

  final String ticker;

  /// Del más reciente al más viejo, como los devuelve el backend.
  final List<EarningsEvent> quarters;

  final int beatCount;
  final int missCount;
  final int inLineCount;

  /// Trimestres con estimación previa: el denominador de [beatRate]. Un trimestre sin estimación no
  /// se puede contar ni como acierto ni como fallo.
  final int measuredQuarters;

  final double? averageSurprisePct;
  final DataAvailability availability;
  final String? degradationReason;
  final bool servedFromCache;

  /// Tasa de aciertos sobre los trimestres MEDIDOS, o `null` si no hubo ninguno. `null` y no 0: una
  /// empresa sin estimaciones disponibles no "falló el 100% de las veces".
  double? get beatRate =>
      measuredQuarters == 0 ? null : beatCount / measuredQuarters;

  /// Cuántos trimestres llegaron sin estimación. Es la diferencia que explica por qué la lista tiene
  /// más filas que el denominador de la tasa.
  int get unmeasuredQuarters => quarters.length - measuredQuarters;
}

// --- Reportes SEC --------------------------------------------------------------------------------

@immutable
class SecFiling {
  const SecFiling({
    required this.ticker,
    required this.filingType,
    required this.filedAt,
    required this.rawType,
    required this.url,
    required this.finalDocumentUrl,
    required this.summary,
    required this.summaryAvailable,
  });

  factory SecFiling.fromJson(Map<String, dynamic> json) => SecFiling(
        ticker: json['ticker'] as String,
        filingType: filingTypeFromWire(json['filing_type'] as String?),
        filedAt: _parseDateTime(json['filed_at']),
        rawType: json['raw_type'] as String?,
        url: json['url'] as String?,
        finalDocumentUrl: json['final_document_url'] as String?,
        summary: json['summary'] as String?,
        summaryAvailable: json['summary_available'] as bool? ?? false,
      );

  final String ticker;
  final FilingType filingType;
  final DateTime? filedAt;

  /// El nombre exacto de la SEC ("10-K/A"). Se muestra cuando difiere del tipo normalizado: la
  /// enmienda de un 10-K no es un 10-K nuevo, y mostrar solo "OTRO" perdería esa diferencia.
  final String? rawType;

  final String? url;
  final String? finalDocumentUrl;

  /// Síntesis generada por IA sobre los METADATOS del reporte. `null` no significa "el reporte no
  /// dice nada": significa que no se sintetizó, y [summaryAvailable] lo distingue.
  final String? summary;
  final bool summaryAvailable;

  /// El enlace a abrir: el documento final si existe, el índice de la presentación si no.
  String? get bestUrl => finalDocumentUrl ?? url;

  /// La etiqueta a mostrar. Prefiere el nombre crudo de la SEC cuando aporta algo (una enmienda),
  /// y cae al tipo normalizado cuando el crudo es redundante o falta.
  String get displayType {
    final raw = rawType?.trim();
    if (raw == null || raw.isEmpty) return filingTypeLabel(filingType);
    return raw;
  }
}

@immutable
class FilingsResponse {
  const FilingsResponse({
    required this.ticker,
    required this.filings,
    required this.availability,
    required this.degradationReason,
    required this.summaryDegradationReason,
    required this.servedFromCache,
  });

  factory FilingsResponse.fromJson(Map<String, dynamic> json) => FilingsResponse(
        ticker: json['ticker'] as String,
        filings: ((json['filings'] as List?) ?? const [])
            .map((item) => SecFiling.fromJson(item as Map<String, dynamic>))
            .toList(),
        availability: availabilityFromWire(json['availability'] as String?),
        degradationReason: json['degradation_reason'] as String?,
        summaryDegradationReason: json['summary_degradation_reason'] as String?,
        servedFromCache: json['served_from_cache'] as bool? ?? false,
      );

  final String ticker;
  final List<SecFiling> filings;
  final DataAvailability availability;
  final String? degradationReason;

  /// Motivo SEPARADO del general: la lista de reportes puede haber llegado perfecta y la síntesis
  /// haber fallado. La UI muestra los dos en lugares distintos, porque significan cosas distintas.
  final String? summaryDegradationReason;

  final bool servedFromCache;

  /// ¿Alguno de los reportes trae síntesis? Decide si el aviso de "sin síntesis" tiene sentido.
  bool get hasAnySummary => filings.any((filing) => filing.summaryAvailable);
}

// --- Noticias ------------------------------------------------------------------------------------

@immutable
class CorporateNewsItem {
  const CorporateNewsItem({
    required this.refId,
    required this.title,
    required this.source,
    required this.publishedAt,
    required this.summary,
    required this.url,
    required this.category,
    required this.sentiment,
    required this.classificationSource,
    required this.tickers,
  });

  factory CorporateNewsItem.fromJson(Map<String, dynamic> json) =>
      CorporateNewsItem(
        refId: json['ref_id'] as String,
        title: json['title'] as String,
        source: json['source'] as String?,
        publishedAt: _parseDateTime(json['published_at']),
        summary: json['summary'] as String?,
        url: json['url'] as String?,
        category: newsCategoryFromWire(json['category'] as String?),
        sentiment: newsSentimentFromWire(json['sentiment'] as String?),
        classificationSource:
            classificationSourceFromWire(json['classification_source'] as String?),
        tickers: ((json['tickers'] as List?) ?? const [])
            .map((item) => item as String)
            .toList(),
      );

  /// Identificador estable derivado de la URL. No es un id del proveedor: sirve para que la UI
  /// pueda dar `key` a cada fila y para citar la noticia dentro de una nota.
  final String refId;

  final String title;

  /// Dominio de la publicación ("reuters.com"). Se muestra siempre: en un feed que mezcla rumores
  /// con hechos, la fuente es justamente lo que permite pesarlos.
  final String? source;

  final DateTime? publishedAt;
  final String? summary;
  final String? url;
  final NewsCategory category;
  final NewsSentiment sentiment;
  final ClassificationSource classificationSource;
  final List<String> tickers;
}

@immutable
class CorporateNewsFeed {
  const CorporateNewsFeed({
    required this.items,
    required this.availability,
    required this.degradationReason,
    required this.servedFromCache,
    required this.appliedTicker,
    required this.appliedCategory,
    required this.appliedSentiment,
    required this.totalBeforeFilters,
  });

  factory CorporateNewsFeed.fromJson(Map<String, dynamic> json) =>
      CorporateNewsFeed(
        items: ((json['items'] as List?) ?? const [])
            .map((item) =>
                CorporateNewsItem.fromJson(item as Map<String, dynamic>))
            .toList(),
        availability: availabilityFromWire(json['availability'] as String?),
        degradationReason: json['degradation_reason'] as String?,
        servedFromCache: json['served_from_cache'] as bool? ?? false,
        appliedTicker: json['applied_ticker'] as String?,
        appliedCategory: json['applied_category'] == null
            ? null
            : newsCategoryFromWire(json['applied_category'] as String?),
        appliedSentiment: json['applied_sentiment'] == null
            ? null
            : newsSentimentFromWire(json['applied_sentiment'] as String?),
        totalBeforeFilters: json['total_before_filters'] as int? ?? 0,
      );

  final List<CorporateNewsItem> items;
  final DataAvailability availability;
  final String? degradationReason;
  final bool servedFromCache;

  /// Los filtros tal como el backend los interpretó. Se muestran para que una lista corta no sea
  /// ambigua: con tres filtros combinables, "1 noticia" puede ser todo lo que hay o el resultado de
  /// un filtro que quedó puesto de antes.
  final String? appliedTicker;
  final NewsCategory? appliedCategory;
  final NewsSentiment? appliedSentiment;

  /// Cuántos ítems trajo el proveedor antes de filtrar. Es lo que deja decir "3 de 20".
  final int totalBeforeFilters;

  int get total => items.length;

  bool get hasFilters =>
      appliedTicker != null || appliedCategory != null || appliedSentiment != null;

  /// ¿La lista está vacía POR los filtros? Es distinto de "no hay noticias": lo primero se arregla
  /// sacando un filtro, lo segundo no se arregla.
  bool get emptiedByFilters =>
      items.isEmpty && totalBeforeFilters > 0 && hasFilters;
}

// --- Parseo tolerante ----------------------------------------------------------------------------

/// Los números del contrato son `float | null`, pero un `int` en el JSON (un ingreso de
/// 46100000000) llega como `int` en Dart y un cast directo a `double` explota. Se convierte en vez
/// de castear.
double? _parseDouble(Object? raw) => switch (raw) {
      final double value => value,
      final int value => value.toDouble(),
      _ => null,
    };

DateTime? _parseDateTime(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}

DateTime? _parseDate(Object? raw) => _parseDateTime(raw);
