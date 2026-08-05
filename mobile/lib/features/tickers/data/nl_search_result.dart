/// Modelos de `POST /api/v1/tickers/search-nl` — la búsqueda conversacional en lenguaje natural.
///
/// Espejan `app/schemas/search.py`. El reparto de trabajo del backend define lo que esta UI tiene
/// que mostrar: **el modelo interpreta, el código filtra**. De ahí los tres campos que la pantalla
/// no puede omitir:
///
///   - `interpretation`: qué entendió el modelo, en prosa. Es lo único que escribió el LLM, y sin
///     mostrarlo una búsqueda vacía por mala interpretación es indistinguible de una búsqueda vacía
///     porque no hay coincidencias.
///   - `matchReason`: por qué entró cada resultado. Lo compone el backend en código con los valores
///     que efectivamente midió, así que es verificable.
///   - `unappliedCriteria`: qué pidió el usuario que NO se pudo filtrar. Su ausencia cambia el
///     significado de la lista entera.
library;

import 'package:flutter/foundation.dart';

import '../../settings/data/exchange_type.dart';
import '../../watchlist/data/portfolio_audit.dart'
    show PortfolioSector, sectorFromWire;

/// De dónde salieron los criterios de búsqueda.
///
/// `textFallback` no es un error: es una búsqueda por coincidencia de texto sobre símbolo y nombre,
/// que es lo que se puede hacer honestamente sin el modelo. La UI lo declara para no presentar
/// resultados pobres como si fueran la respuesta a lo que el usuario preguntó.
enum CriteriaSource { ai, textFallback }

/// `textFallback` como fallback de parseo: es la afirmación más débil de las dos, así que un valor
/// desconocido degrada la confianza en el resultado en vez de inflarla.
CriteriaSource criteriaSourceFromWire(String? value) =>
    value == 'AI' ? CriteriaSource.ai : CriteriaSource.textFallback;

@immutable
class NumericRange {
  const NumericRange({required this.minimum, required this.maximum});

  factory NumericRange.fromJson(Map<String, dynamic> json) => NumericRange(
        minimum: (json['minimum'] as num?)?.toDouble(),
        maximum: (json['maximum'] as num?)?.toDouble(),
      );

  static const empty = NumericRange(minimum: null, maximum: null);

  final double? minimum;
  final double? maximum;

  bool get isEmpty => minimum == null && maximum == null;

  /// Descripción legible del rango, para el chip de criterios. Los dos extremos son opcionales:
  /// "P/E menor a 20" es un rango con solo máximo, y mostrar un mínimo inventado (0) afirmaría un
  /// filtro que el usuario no pidió.
  String describe(String label) {
    final low = minimum;
    final high = maximum;
    if (low != null && high != null) {
      return '$label ${_format(low)}–${_format(high)}';
    }
    if (high != null) return '$label < ${_format(high)}';
    if (low != null) return '$label > ${_format(low)}';
    return label;
  }

  /// Formato para chips: sin decimales cuando el valor es entero y sin ceros al final cuando no lo
  /// es ("15", "0.5"), porque "15.00" y "0.50" en un chip de dos palabras se leen como precisión
  /// que el criterio no tiene. Los montos grandes (capitalización) se dejan en notación completa:
  /// acortarlos acá los haría ambiguos con los múltiplos.
  static String _format(double value) {
    if (value == value.roundToDouble() && value.abs() < 1e6) {
      return value.toStringAsFixed(0);
    }
    return value
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
}

/// Lo que el modelo entendió de la consulta, ya normalizado por el backend.
///
/// Se expone para que la pantalla pueda mostrar los criterios como chips: es la forma de que el
/// usuario detecte al toque una interpretación equivocada, que es el modo de falla propio de una
/// búsqueda en lenguaje natural.
@immutable
class SearchCriteria {
  const SearchCriteria({
    required this.sectors,
    required this.exchanges,
    required this.priceEarnings,
    required this.debtToEquity,
    required this.returnOnEquityPct,
    required this.revenueGrowthYoyPct,
    required this.marketCapUsd,
    required this.freeCashFlowPositive,
    required this.textQuery,
  });

  factory SearchCriteria.fromJson(Map<String, dynamic> json) => SearchCriteria(
        sectors: [
          for (final sector in json['sectors'] as List? ?? [])
            sectorFromWire(sector as String?),
        ],
        exchanges: [
          for (final exchange in json['exchanges'] as List? ?? [])
            if (exchangeTypeFromWire(exchange as String?) case final parsed?)
              parsed,
        ],
        priceEarnings: _range(json['price_earnings']),
        debtToEquity: _range(json['debt_to_equity']),
        returnOnEquityPct: _range(json['return_on_equity_pct']),
        revenueGrowthYoyPct: _range(json['revenue_growth_yoy_pct']),
        marketCapUsd: _range(json['market_cap_usd']),
        freeCashFlowPositive: json['free_cash_flow_positive'] as bool?,
        textQuery: json['text_query'] as String?,
      );

  static const empty = SearchCriteria(
    sectors: [],
    exchanges: [],
    priceEarnings: NumericRange.empty,
    debtToEquity: NumericRange.empty,
    returnOnEquityPct: NumericRange.empty,
    revenueGrowthYoyPct: NumericRange.empty,
    marketCapUsd: NumericRange.empty,
    freeCashFlowPositive: null,
    textQuery: null,
  );

  static NumericRange _range(Object? raw) => raw is Map<String, dynamic>
      ? NumericRange.fromJson(raw)
      : NumericRange.empty;

  final List<PortfolioSector> sectors;
  final List<ExchangeType> exchanges;
  final NumericRange priceEarnings;
  final NumericRange debtToEquity;
  final NumericRange returnOnEquityPct;
  final NumericRange revenueGrowthYoyPct;
  final NumericRange marketCapUsd;

  /// `null` es "no lo pidió", distinto de `false` ("que NO genere caja"), que también es una
  /// búsqueda válida.
  final bool? freeCashFlowPositive;
  final String? textQuery;

  /// Los criterios numéricos como texto, para los chips. El orden es fijo para que dos búsquedas
  /// parecidas se lean igual.
  List<String> get numericLabels => [
        if (!priceEarnings.isEmpty) priceEarnings.describe('P/E'),
        if (!debtToEquity.isEmpty) debtToEquity.describe('Deuda/Equity'),
        if (!returnOnEquityPct.isEmpty) returnOnEquityPct.describe('ROE'),
        if (!revenueGrowthYoyPct.isEmpty)
          revenueGrowthYoyPct.describe('Crecimiento'),
        if (!marketCapUsd.isEmpty) marketCapUsd.describe('Cap.'),
        if (freeCashFlowPositive == true) 'Genera caja',
        if (freeCashFlowPositive == false) 'No genera caja',
      ];
}

@immutable
class NlTickerMatch {
  const NlTickerMatch({
    required this.symbol,
    required this.name,
    required this.exchange,
    required this.sector,
    required this.sectorLabel,
    required this.matchReason,
    required this.priceEarnings,
    required this.debtToEquity,
    required this.returnOnEquityPct,
    required this.revenueGrowthYoyPct,
    required this.marketCapUsd,
  });

  factory NlTickerMatch.fromJson(Map<String, dynamic> json) => NlTickerMatch(
        symbol: json['symbol'] as String,
        name: json['name'] as String,
        exchange: exchangeTypeFromWire(json['exchange'] as String?),
        sector: sectorFromWire(json['sector'] as String?),
        sectorLabel: json['sector_label'] as String? ?? '—',
        matchReason: json['match_reason'] as String? ?? '',
        priceEarnings: (json['price_earnings'] as num?)?.toDouble(),
        debtToEquity: (json['debt_to_equity'] as num?)?.toDouble(),
        returnOnEquityPct: (json['return_on_equity_pct'] as num?)?.toDouble(),
        revenueGrowthYoyPct:
            (json['revenue_growth_yoy_pct'] as num?)?.toDouble(),
        marketCapUsd: (json['market_cap_usd'] as num?)?.toDouble(),
      );

  final String symbol;
  final String name;

  /// `null` cuando el backend devolvió `OTHER` — una bolsa que el producto todavía no ofrece
  /// elegir, no un error de parseo.
  final ExchangeType? exchange;
  final PortfolioSector sector;
  final String sectorLabel;

  /// Por qué entró este símbolo, compuesto por el backend con los valores medidos. Se muestra tal
  /// cual: es la parte auditable del resultado.
  final String matchReason;

  final double? priceEarnings;
  final double? debtToEquity;
  final double? returnOnEquityPct;
  final double? revenueGrowthYoyPct;
  final double? marketCapUsd;

  /// Los ratios que se midieron, ya formateados, para mostrarlos como chips sin otra consulta.
  /// Solo los que tienen valor: un hueco no se rellena con 0.
  List<(String, String)> get ratioChips => [
        if (priceEarnings != null)
          ('P/E', '${priceEarnings!.toStringAsFixed(2)}x'),
        if (debtToEquity != null)
          ('D/E', '${debtToEquity!.toStringAsFixed(2)}x'),
        if (returnOnEquityPct != null)
          ('ROE', '${returnOnEquityPct!.toStringAsFixed(1)}%'),
        if (revenueGrowthYoyPct != null)
          ('Crec.', '${revenueGrowthYoyPct!.toStringAsFixed(1)}%'),
        if (marketCapUsd != null) ('Cap.', _compactUsd(marketCapUsd!)),
      ];

  static String _compactUsd(double value) {
    final sign = value < 0 ? '-' : '';
    final abs = value.abs();
    if (abs >= 1e12) return '$sign\$${(abs / 1e12).toStringAsFixed(2)}B';
    if (abs >= 1e9) return '$sign\$${(abs / 1e9).toStringAsFixed(1)}MM';
    if (abs >= 1e6) return '$sign\$${(abs / 1e6).toStringAsFixed(0)}M';
    return '$sign\$${abs.toStringAsFixed(0)}';
  }
}

@immutable
class NlSearchResult {
  const NlSearchResult({
    required this.query,
    required this.interpretation,
    required this.criteria,
    required this.criteriaSource,
    required this.results,
    required this.candidatesEvaluated,
    required this.aiAvailable,
    required this.metricsAvailable,
    required this.unappliedCriteria,
    required this.degradationReason,
  });

  factory NlSearchResult.fromJson(Map<String, dynamic> json) => NlSearchResult(
        query: json['query'] as String? ?? '',
        interpretation: json['interpretation'] as String?,
        criteria: json['criteria'] is Map<String, dynamic>
            ? SearchCriteria.fromJson(json['criteria'] as Map<String, dynamic>)
            : SearchCriteria.empty,
        criteriaSource:
            criteriaSourceFromWire(json['criteria_source'] as String?),
        results: [
          for (final match in json['results'] as List? ?? [])
            NlTickerMatch.fromJson(match as Map<String, dynamic>),
        ],
        candidatesEvaluated:
            (json['candidates_evaluated'] as num?)?.toInt() ?? 0,
        aiAvailable: json['ai_available'] as bool? ?? false,
        metricsAvailable: json['metrics_available'] as bool? ?? false,
        unappliedCriteria: [
          for (final criterion in json['unapplied_criteria'] as List? ?? [])
            criterion as String,
        ],
        degradationReason: json['degradation_reason'] as String?,
      );

  final String query;

  /// Reformulación en prosa de lo que el modelo entendió. `null` cuando no hubo interpretación
  /// (búsqueda por texto).
  final String? interpretation;
  final SearchCriteria criteria;
  final CriteriaSource criteriaSource;
  final List<NlTickerMatch> results;

  /// Cuántos símbolos del catálogo pasaron los filtros locales antes de mirar los ratios. Deja ver
  /// que "3 resultados" salieron de evaluar 40 candidatos, no de que el catálogo tenga 3.
  final int candidatesEvaluated;
  final bool aiAvailable;
  final bool metricsAvailable;

  /// Criterios que el modelo entendió pero que no se pudieron aplicar. La UI los muestra siempre:
  /// sin ellos, la lista NO cumple lo que el usuario pidió y presentarla como si lo cumpliera
  /// sería una respuesta falsa.
  final List<String> unappliedCriteria;
  final String? degradationReason;

  bool get isEmpty => results.isEmpty;

  /// `true` cuando la interpretación con IA funcionó. Lo usa la UI para decidir si mostrar la
  /// tarjeta de interpretación o el aviso de que se buscó por texto.
  bool get wasInterpreted => criteriaSource == CriteriaSource.ai;
}
