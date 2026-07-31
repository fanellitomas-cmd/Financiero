/// Modelos que espejan `src/validation/domain_models.py` del backend (el `PushNotificationPayload`
/// que produce el Nodo 5). Se hand-codean (sin `json_serializable`/build_runner) a propósito:
/// son pocos campos, cambian poco, y así el proyecto no depende de un paso de codegen para
/// compilar — si el equipo prefiere codegen más adelante, migrar acá es directo.
library;

enum AlertUrgency { low, medium, high, critical }

AlertUrgency alertUrgencyFromJson(String value) => switch (value) {
      'LOW' => AlertUrgency.low,
      'MEDIUM' => AlertUrgency.medium,
      'HIGH' => AlertUrgency.high,
      'CRITICAL' => AlertUrgency.critical,
      _ => throw ArgumentError('AlertUrgency desconocido: $value'),
    };

enum ScenarioLabel { alcista, neutral, bajista }

ScenarioLabel scenarioLabelFromJson(String value) => switch (value) {
      'ALCISTA' => ScenarioLabel.alcista,
      'NEUTRAL' => ScenarioLabel.neutral,
      'BAJISTA' => ScenarioLabel.bajista,
      _ => throw ArgumentError('ScenarioLabel desconocido: $value'),
    };

enum InvestmentHorizon { cortoPlazo, medianoPlazo, largoPlazo }

InvestmentHorizon horizonFromJson(String value) => switch (value) {
      'CORTO_1_14D' => InvestmentHorizon.cortoPlazo,
      'MEDIANO_1_6M' => InvestmentHorizon.medianoPlazo,
      'LARGO_1_3A' => InvestmentHorizon.largoPlazo,
      _ => throw ArgumentError('InvestmentHorizon desconocido: $value'),
    };

extension InvestmentHorizonLabel on InvestmentHorizon {
  String get displayLabel => switch (this) {
        InvestmentHorizon.cortoPlazo => 'Corto plazo (1-14 días)',
        InvestmentHorizon.medianoPlazo => 'Mediano plazo (1-6 meses)',
        InvestmentHorizon.largoPlazo => 'Largo plazo (1-3 años)',
      };
}

class ScenarioOutcome {
  const ScenarioOutcome({
    required this.label,
    required this.probabilityPct,
    required this.rationale,
  });

  factory ScenarioOutcome.fromJson(Map<String, dynamic> json) => ScenarioOutcome(
        label: scenarioLabelFromJson(json['label'] as String),
        probabilityPct: double.parse(json['probability_pct'].toString()),
        rationale: json['rationale'] as String,
      );

  final ScenarioLabel label;
  final double probabilityPct;
  final String rationale;
}

class HorizonScenarios {
  const HorizonScenarios({
    required this.horizon,
    required this.scenarios,
    required this.confidenceLevel,
  });

  factory HorizonScenarios.fromJson(Map<String, dynamic> json) => HorizonScenarios(
        horizon: horizonFromJson(json['horizon'] as String),
        scenarios: (json['scenarios'] as List)
            .map((item) => ScenarioOutcome.fromJson(item as Map<String, dynamic>))
            .toList(),
        confidenceLevel: json['confidence_level'] as String,
      );

  final InvestmentHorizon horizon;
  final List<ScenarioOutcome> scenarios;
  final String confidenceLevel;
}

class AssetProjection {
  const AssetProjection({required this.horizons, required this.classification});

  factory AssetProjection.fromJson(Map<String, dynamic> json) => AssetProjection(
        horizons: (json['horizons'] as List)
            .map((item) => HorizonScenarios.fromJson(item as Map<String, dynamic>))
            .toList(),
        classification: json['classification'] as String,
      );

  final List<HorizonScenarios> horizons;
  final String classification;
}

class AnalysisNarrative {
  const AnalysisNarrative({required this.headline, required this.horizonExplanations});

  factory AnalysisNarrative.fromJson(Map<String, dynamic> json) => AnalysisNarrative(
        headline: json['headline'] as String,
        horizonExplanations: (json['horizon_explanations'] as List? ?? [])
            .map((item) => item as String)
            .toList(),
      );

  final String headline;
  final List<String> horizonExplanations;
}

/// El payload en vivo que llega por `WS /api/v1/ws/{ticker}` o que arma la Ficha al abrir un
/// activo. Trae SIEMPRE las dos narrativas (`technicalNarrative`/`beginnerNarrative`): el
/// toggle "Explicar para Principiantes" es una decisión 100% del cliente, no requiere un
/// nuevo pedido al backend (ver docstring de `AnalysisNarrative` en el motor).
class PushNotificationPayload {
  const PushNotificationPayload({
    required this.notificationId,
    required this.ticker,
    required this.title,
    required this.shortSummary,
    required this.technicalNarrative,
    required this.beginnerNarrative,
    required this.defaultViewIsBeginner,
    required this.urgencyLevel,
    required this.timestamp,
    this.fullAnalysis,
  });

  factory PushNotificationPayload.fromJson(Map<String, dynamic> json) =>
      PushNotificationPayload(
        notificationId: json['notification_id'] as String,
        ticker: json['ticker'] as String,
        title: json['title'] as String,
        shortSummary: json['short_summary'] as String,
        technicalNarrative:
            AnalysisNarrative.fromJson(json['technical_narrative'] as Map<String, dynamic>),
        beginnerNarrative:
            AnalysisNarrative.fromJson(json['beginner_narrative'] as Map<String, dynamic>),
        defaultViewIsBeginner: json['default_view'] == 'beginner',
        urgencyLevel: alertUrgencyFromJson(json['urgency_level'] as String),
        timestamp: DateTime.parse(json['timestamp'] as String),
        fullAnalysis: json['full_analysis_json'] == null
            ? null
            : AssetProjection.fromJson(json['full_analysis_json'] as Map<String, dynamic>),
      );

  final String notificationId;
  final String ticker;
  final String title;
  final String shortSummary;
  final AnalysisNarrative technicalNarrative;
  final AnalysisNarrative beginnerNarrative;
  final bool defaultViewIsBeginner;
  final AlertUrgency urgencyLevel;
  final DateTime timestamp;
  final AssetProjection? fullAnalysis;
}
