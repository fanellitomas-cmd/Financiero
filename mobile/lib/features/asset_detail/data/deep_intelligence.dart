/// Modelos de `GET /api/v1/tickers/{ticker}/intelligence` — la Ficha de Inteligencia Profunda.
///
/// Espejan `app/schemas/intelligence.py`. El principio que gobierna el parseo: **todo enum que
/// venga del backend se parsea con fallback, nunca con `throw`**. Un valor nuevo del lado del
/// servidor (un tono de salud financiera agregado después, una tendencia distinta) tiene que
/// degradar ese dato puntual, no tirar abajo la Ficha entera — que es justamente lo contrario de
/// lo que el backend se tomó el trabajo de garantizar con sus `availability`.
library;

import 'package:flutter/foundation.dart';

import '../../../core/data/data_availability.dart';

// Se re-exporta para que todo lo que ya importaba `DataAvailability` desde acá siga funcionando:
// el enum se mudó a `core/` cuando la Auditoría de Portafolio pasó a usar el mismo contrato, y
// mover el símbolo sin re-exportarlo habría roto a cada consumidor de la Ficha sin ninguna razón
// de fondo.
export '../../../core/data/data_availability.dart'
    show DataAvailability, availabilityFromWire;

/// Semáforo de salud financiera. Lo calcula el backend en código con umbrales explícitos (no el
/// LLM), así que es determinístico: los mismos ratios dan siempre el mismo veredicto.
enum FinancialHealth { solida, adecuada, ajustada, debil, indeterminada }

FinancialHealth financialHealthFromWire(String? value) => switch (value) {
      'SOLIDA' => FinancialHealth.solida,
      'ADECUADA' => FinancialHealth.adecuada,
      'AJUSTADA' => FinancialHealth.ajustada,
      'DEBIL' => FinancialHealth.debil,
      _ => FinancialHealth.indeterminada,
    };

enum TrendDirection { alcista, lateral, bajista }

/// `lateral` como fallback, igual que hace el backend: es la afirmación más débil de las tres, así
/// que un valor inesperado degrada la señal en vez de fortalecerla.
TrendDirection trendFromWire(String? value) => switch (value) {
      'ALCISTA' => TrendDirection.alcista,
      'BAJISTA' => TrendDirection.bajista,
      _ => TrendDirection.lateral,
    };

enum ConfidenceLevel { baja, media, alta }

ConfidenceLevel confidenceFromWire(String? value) => switch (value) {
      'ALTA' => ConfidenceLevel.alta,
      'MEDIA' => ConfidenceLevel.media,
      _ => ConfidenceLevel.baja,
    };

enum ConvictionLevel { baja, moderada, alta }

ConvictionLevel convictionFromWire(String? value) => switch (value) {
      'ALTA' => ConvictionLevel.alta,
      'MODERADA' => ConvictionLevel.moderada,
      _ => ConvictionLevel.baja,
    };

/// Un ratio con su etiqueta y unidad ya resueltas del lado del backend.
///
/// El cliente no decide etiquetas ni unidades a propósito: si el backend agrega un ratio, aparece
/// solo. `value == null` significa que el proveedor no lo trajo — se muestra "—", nunca un 0, que
/// se leería como un dato real.
@immutable
class RatioValue {
  const RatioValue({
    required this.label,
    required this.value,
    required this.unit,
  });

  factory RatioValue.fromJson(Map<String, dynamic> json) => RatioValue(
        label: json['label'] as String,
        value: (json['value'] as num?)?.toDouble(),
        unit: json['unit'] as String?,
      );

  final String label;
  final double? value;
  final String? unit;

  bool get isAvailable => value != null;

  /// Valor formateado según su unidad.
  ///
  /// Los porcentajes se normalizan porque FMP devuelve márgenes como fracción (0.72) o como
  /// porcentaje (72) según el endpoint: sin esto, un margen del 72% se mostraría como "0.72%".
  String get formatted {
    final raw = value;
    if (raw == null) return '—';
    return switch (unit) {
      '%' => '${(raw.abs() <= 1 ? raw * 100 : raw).toStringAsFixed(2)}%',
      'USD' => _compactUsd(raw),
      'x' => '${raw.toStringAsFixed(2)}x',
      _ => raw.toStringAsFixed(2),
    };
  }

  /// Montos en notación compacta: un FCF de 60.800.000.000 en una celda de grilla no entra, y
  /// "USD 60,80 MM" se lee de un vistazo.
  static String _compactUsd(double value) {
    final sign = value < 0 ? '-' : '';
    final abs = value.abs();
    if (abs >= 1e12) return '$sign\$${(abs / 1e12).toStringAsFixed(2)} B';
    if (abs >= 1e9) return '$sign\$${(abs / 1e9).toStringAsFixed(2)} MM';
    if (abs >= 1e6) return '$sign\$${(abs / 1e6).toStringAsFixed(1)} M';
    return '$sign\$${abs.toStringAsFixed(0)}';
  }
}

@immutable
class Fundamentals {
  const Fundamentals({
    required this.availability,
    required this.asOf,
    required this.period,
    required this.ratios,
    required this.financialHealth,
    required this.financialHealthNotes,
    required this.degradationReason,
  });

  /// Los ratios se leen en un orden FIJO y explícito (valuación → apalancamiento → caja →
  /// rentabilidad → liquidez → crecimiento), no iterando las claves del JSON: el orden de un mapa
  /// JSON no es contrato, y una grilla de ratios que cambia de orden entre requests es imposible
  /// de leer.
  static const List<String> ratioKeys = [
    'price_earnings',
    'price_earnings_growth',
    'debt_to_equity',
    'debt_to_ebitda',
    'free_cash_flow',
    'free_cash_flow_yield_pct',
    'gross_margin_pct',
    'operating_margin_pct',
    'return_on_equity_pct',
    'current_ratio',
    'revenue_growth_yoy_pct',
  ];

  factory Fundamentals.fromJson(Map<String, dynamic> json) => Fundamentals(
        availability: availabilityFromWire(json['availability'] as String?),
        asOf: json['as_of'] == null
            ? null
            : DateTime.parse(json['as_of'] as String),
        period: json['period'] as String?,
        ratios: [
          for (final key in ratioKeys)
            if (json[key] case final Map<String, dynamic> raw)
              RatioValue.fromJson(raw),
        ],
        financialHealth: financialHealthFromWire(
          json['financial_health'] as String?,
        ),
        financialHealthNotes: [
          for (final note in json['financial_health_notes'] as List? ?? [])
            note as String,
        ],
        degradationReason: json['degradation_reason'] as String?,
      );

  final DataAvailability availability;
  final DateTime? asOf;
  final String? period;
  final List<RatioValue> ratios;
  final FinancialHealth financialHealth;
  final List<String> financialHealthNotes;
  final String? degradationReason;

  /// Cuántos ratios tienen valor. Lo usa la UI para el subtítulo "8 de 11 disponibles" cuando el
  /// bloque viene `partial`.
  int get availableCount => ratios.where((ratio) => ratio.isAvailable).length;
}

@immutable
class SourceReference {
  const SourceReference({
    required this.refId,
    required this.sourceType,
    required this.title,
    required this.url,
    required this.publishedAt,
  });

  factory SourceReference.fromJson(Map<String, dynamic> json) =>
      SourceReference(
        refId: json['ref_id'] as String,
        sourceType: json['source_type'] as String,
        title: json['title'] as String?,
        url: json['url'] as String?,
        publishedAt: json['published_at'] == null
            ? null
            : DateTime.parse(json['published_at'] as String),
      );

  final String refId;
  final String sourceType;
  final String? title;
  final String? url;
  final DateTime? publishedAt;

  /// `true` para 10-K/10-Q y transcripciones: son reportes oficiales, y la UI los separa de las
  /// noticias en pestañas distintas porque tienen peso probatorio distinto.
  bool get isOfficialFiling =>
      sourceType.startsWith('SEC_') ||
      sourceType == 'EARNINGS_TRANSCRIPT' ||
      sourceType == 'OFFICIAL_ANNOUNCEMENT';
}

@immutable
class RagSummary {
  const RagSummary({
    required this.availability,
    required this.headline,
    required this.keyPoints,
    required this.risks,
    required this.sources,
    required this.degradationReason,
  });

  factory RagSummary.fromJson(Map<String, dynamic> json) => RagSummary(
        availability: availabilityFromWire(json['availability'] as String?),
        headline: json['headline'] as String?,
        keyPoints: [
          for (final point in json['key_points'] as List? ?? [])
            point as String,
        ],
        risks: [
          for (final risk in json['risks'] as List? ?? []) risk as String
        ],
        sources: [
          for (final source in json['sources'] as List? ?? [])
            SourceReference.fromJson(source as Map<String, dynamic>),
        ],
        degradationReason: json['degradation_reason'] as String?,
      );

  final DataAvailability availability;
  final String? headline;
  final List<String> keyPoints;
  final List<String> risks;
  final List<SourceReference> sources;
  final String? degradationReason;

  List<SourceReference> get filings =>
      sources.where((source) => source.isOfficialFiling).toList();

  List<SourceReference> get news =>
      sources.where((source) => !source.isOfficialFiling).toList();
}

@immutable
class ShortTermProjection {
  const ShortTermProjection({
    required this.horizonLabel,
    required this.trend,
    required this.confidence,
    required this.argument,
    required this.evidenceRefs,
  });

  factory ShortTermProjection.fromJson(Map<String, dynamic> json) =>
      ShortTermProjection(
        horizonLabel: json['horizon_label'] as String,
        trend: trendFromWire(json['trend'] as String?),
        confidence: confidenceFromWire(json['confidence'] as String?),
        argument: json['argument'] as String,
        evidenceRefs: _refs(json['evidence_refs']),
      );

  final String horizonLabel;
  final TrendDirection trend;
  final ConfidenceLevel confidence;
  final String argument;
  final List<String> evidenceRefs;
}

@immutable
class ScenarioOutlook {
  const ScenarioOutlook({
    required this.label,
    required this.narrative,
    required this.probabilityPct,
  });

  factory ScenarioOutlook.fromJson(Map<String, dynamic> json) =>
      ScenarioOutlook(
        label: json['label'] as String,
        narrative: json['narrative'] as String,
        probabilityPct: (json['probability_pct'] as num?)?.toDouble(),
      );

  final String label;
  final String narrative;

  /// `null` cuando el modelo no tuvo base para cuantificar. La UI omite la barra en ese caso en
  /// vez de dibujar una en 0, que se leería como "escenario descartado".
  final double? probabilityPct;
}

@immutable
class MediumTermProjection {
  const MediumTermProjection({
    required this.horizonLabel,
    required this.baseCase,
    required this.bullCase,
    required this.bearCase,
    required this.catalysts,
    required this.confidence,
    required this.evidenceRefs,
  });

  factory MediumTermProjection.fromJson(Map<String, dynamic> json) =>
      MediumTermProjection(
        horizonLabel: json['horizon_label'] as String,
        baseCase: ScenarioOutlook.fromJson(
          json['base_case'] as Map<String, dynamic>,
        ),
        bullCase: ScenarioOutlook.fromJson(
          json['bull_case'] as Map<String, dynamic>,
        ),
        bearCase: ScenarioOutlook.fromJson(
          json['bear_case'] as Map<String, dynamic>,
        ),
        catalysts: [
          for (final catalyst in json['catalysts'] as List? ?? [])
            catalyst as String,
        ],
        confidence: confidenceFromWire(json['confidence'] as String?),
        evidenceRefs: _refs(json['evidence_refs']),
      );

  final String horizonLabel;
  final ScenarioOutlook baseCase;
  final ScenarioOutlook bullCase;
  final ScenarioOutlook bearCase;
  final List<String> catalysts;
  final ConfidenceLevel confidence;
  final List<String> evidenceRefs;

  /// Base primero: es el escenario de referencia, no un promedio de los otros dos.
  List<ScenarioOutlook> get scenarios => [baseCase, bullCase, bearCase];
}

@immutable
class LongTermProjection {
  const LongTermProjection({
    required this.horizonLabel,
    required this.thesis,
    required this.conviction,
    required this.supportingFactors,
    required this.invalidationTriggers,
    required this.evidenceRefs,
  });

  factory LongTermProjection.fromJson(Map<String, dynamic> json) =>
      LongTermProjection(
        horizonLabel: json['horizon_label'] as String,
        thesis: json['thesis'] as String,
        conviction: convictionFromWire(json['conviction'] as String?),
        supportingFactors: [
          for (final factor in json['supporting_factors'] as List? ?? [])
            factor as String,
        ],
        invalidationTriggers: [
          for (final trigger in json['invalidation_triggers'] as List? ?? [])
            trigger as String,
        ],
        evidenceRefs: _refs(json['evidence_refs']),
      );

  final String horizonLabel;
  final String thesis;
  final ConvictionLevel conviction;
  final List<String> supportingFactors;

  /// Qué invalidaría la tesis. El backend lo exige como campo obligatorio del modelo: una tesis
  /// sin condiciones de invalidación no es una tesis.
  final List<String> invalidationTriggers;
  final List<String> evidenceRefs;
}

@immutable
class Projections {
  const Projections({
    required this.availability,
    required this.shortTerm,
    required this.mediumTerm,
    required this.longTerm,
    required this.degradationReason,
  });

  factory Projections.fromJson(Map<String, dynamic> json) => Projections(
        availability: availabilityFromWire(json['availability'] as String?),
        shortTerm: json['short_term'] == null
            ? null
            : ShortTermProjection.fromJson(
                json['short_term'] as Map<String, dynamic>,
              ),
        mediumTerm: json['medium_term'] == null
            ? null
            : MediumTermProjection.fromJson(
                json['medium_term'] as Map<String, dynamic>,
              ),
        longTerm: json['long_term'] == null
            ? null
            : LongTermProjection.fromJson(
                json['long_term'] as Map<String, dynamic>,
              ),
        degradationReason: json['degradation_reason'] as String?,
      );

  final DataAvailability availability;
  final ShortTermProjection? shortTerm;
  final MediumTermProjection? mediumTerm;
  final LongTermProjection? longTerm;
  final String? degradationReason;

  /// Cada horizonte es opcional por separado: el modelo puede tener base para el corto y no para
  /// el largo, y en ese caso se muestra lo que hay.
  bool get hasAny =>
      shortTerm != null || mediumTerm != null || longTerm != null;
}

@immutable
class DeepIntelligence {
  const DeepIntelligence({
    required this.ticker,
    required this.companyName,
    required this.generatedAt,
    required this.fundamentals,
    required this.ragSummary,
    required this.projections,
    required this.servedFromCache,
  });

  factory DeepIntelligence.fromJson(Map<String, dynamic> json) =>
      DeepIntelligence(
        ticker: json['ticker'] as String,
        companyName: json['company_name'] as String?,
        generatedAt: DateTime.parse(json['generated_at'] as String),
        fundamentals: Fundamentals.fromJson(
          json['fundamentals'] as Map<String, dynamic>,
        ),
        ragSummary: RagSummary.fromJson(
          json['rag_summary'] as Map<String, dynamic>,
        ),
        projections: Projections.fromJson(
          json['projections'] as Map<String, dynamic>,
        ),
        servedFromCache: json['served_from_cache'] as bool? ?? false,
      );

  final String ticker;
  final String? companyName;
  final DateTime generatedAt;
  final Fundamentals fundamentals;
  final RagSummary ragSummary;
  final Projections projections;
  final bool servedFromCache;

  /// `true` solo si los tres bloques están completos. La UI lo usa para decidir si mostrar el
  /// aviso general de "Ficha parcial" en la cabecera.
  bool get isFullyAvailable =>
      fundamentals.availability == DataAvailability.available &&
      ragSummary.availability == DataAvailability.available &&
      projections.availability == DataAvailability.available;
}

List<String> _refs(Object? raw) => [
      for (final ref in raw as List? ?? []) ref as String,
    ];
