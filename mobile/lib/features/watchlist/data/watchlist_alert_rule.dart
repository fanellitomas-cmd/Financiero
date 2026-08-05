/// Modelos de `/api/v1/watchlist/alerts` — las reglas de alerta contextuales de la Watchlist.
///
/// Espejan `app/schemas/watchlist_alert.py`. Tres tipos con parámetros propios:
///   - `price`: umbral de variación porcentual.
///   - `newsSeverity`: severidad mínima de la noticia, y opcionalmente que la lectura sea negativa.
///   - `trendBreak`: quiebre de tendencia en un horizonte, con dirección y probabilidad mínima.
///
/// **El backend rechaza (422) los parámetros de otro tipo**, y con razón: una regla que parece
/// configurada pero cuyo parámetro nadie lee es peor que un error. Por eso el cuerpo del request no
/// se arma a mano en la UI sino en `WatchlistAlertRuleDraft.toCreateJson`, que emite únicamente los
/// campos del tipo elegido — así es imposible mandar un campo ajeno desde una pantalla.
library;

import 'package:flutter/foundation.dart';

enum AlertRuleType { price, newsSeverity, trendBreak }

extension AlertRuleTypeWire on AlertRuleType {
  String get wireValue => switch (this) {
        AlertRuleType.price => 'PRICE',
        AlertRuleType.newsSeverity => 'NEWS_SEVERITY',
        AlertRuleType.trendBreak => 'TREND_BREAK',
      };

  String get displayName => switch (this) {
        AlertRuleType.price => 'Por precio',
        AlertRuleType.newsSeverity => 'Por noticias',
        AlertRuleType.trendBreak => 'Por tendencia',
      };

  /// Qué mira cada regla, en una línea. Va en la UI porque la diferencia entre las tres no es
  /// obvia: las tres "avisan de algo malo", y sin esta explicación el usuario no sabe cuál elegir.
  String get description => switch (this) {
        AlertRuleType.price =>
          'Avisa cuando el precio se mueve más de lo que indiques, para arriba o para abajo.',
        AlertRuleType.newsSeverity =>
          'Avisa cuando hay una noticia grave o un cambio real en los fundamentos, no un simple '
              'movimiento de precio.',
        AlertRuleType.trendBreak =>
          'Avisa cuando la proyección del agente para un horizonte se da vuelta.',
      };
}

/// `price` como fallback: es el tipo que siempre existió, así que una regla de un tipo que este
/// cliente no conoce se muestra como la más básica en vez de romper la pantalla.
AlertRuleType alertRuleTypeFromWire(String? value) => switch (value) {
      'PRICE' => AlertRuleType.price,
      'NEWS_SEVERITY' => AlertRuleType.newsSeverity,
      'TREND_BREAK' => AlertRuleType.trendBreak,
      _ => AlertRuleType.price,
    };

/// Severidad del motor de alertas (`src/validation/domain_models.py::AlertSeverity`).
enum AlertSeverity { low, medium, high, critical }

extension AlertSeverityWire on AlertSeverity {
  String get wireValue => switch (this) {
        AlertSeverity.low => 'LOW',
        AlertSeverity.medium => 'MEDIUM',
        AlertSeverity.high => 'HIGH',
        AlertSeverity.critical => 'CRITICAL',
      };

  String get displayName => switch (this) {
        AlertSeverity.low => 'Baja',
        AlertSeverity.medium => 'Media',
        AlertSeverity.high => 'Alta',
        AlertSeverity.critical => 'Crítica',
      };
}

AlertSeverity alertSeverityFromWire(String? value) => switch (value) {
      'LOW' => AlertSeverity.low,
      'MEDIUM' => AlertSeverity.medium,
      'CRITICAL' => AlertSeverity.critical,
      // `high` como fallback: es el default del producto para una regla de noticias.
      _ => AlertSeverity.high,
    };

enum TrendHorizon { corto, mediano, largo }

extension TrendHorizonWire on TrendHorizon {
  String get wireValue => switch (this) {
        TrendHorizon.corto => 'CORTO',
        TrendHorizon.mediano => 'MEDIANO',
        TrendHorizon.largo => 'LARGO',
      };

  /// Los mismos rangos que usa la Ficha de Inteligencia Profunda, para que "mediano plazo"
  /// signifique lo mismo en las dos pantallas.
  String get displayName => switch (this) {
        TrendHorizon.corto => 'Corto (1-14 días)',
        TrendHorizon.mediano => 'Mediano (1-6 meses)',
        TrendHorizon.largo => 'Largo (1-3 años)',
      };

  String get shortName => switch (this) {
        TrendHorizon.corto => 'corto plazo',
        TrendHorizon.mediano => 'mediano plazo',
        TrendHorizon.largo => 'largo plazo',
      };
}

TrendHorizon trendHorizonFromWire(String? value) => switch (value) {
      'CORTO' => TrendHorizon.corto,
      'LARGO' => TrendHorizon.largo,
      _ => TrendHorizon.mediano,
    };

enum TrendBreakDirection { bajista, alcista, cualquiera }

extension TrendBreakDirectionWire on TrendBreakDirection {
  String get wireValue => switch (this) {
        TrendBreakDirection.bajista => 'BAJISTA',
        TrendBreakDirection.alcista => 'ALCISTA',
        TrendBreakDirection.cualquiera => 'CUALQUIERA',
      };

  String get displayName => switch (this) {
        TrendBreakDirection.bajista => 'Se da vuelta en contra',
        TrendBreakDirection.alcista => 'Se da vuelta a favor',
        TrendBreakDirection.cualquiera => 'Cualquiera de las dos',
      };
}

TrendBreakDirection trendDirectionFromWire(String? value) => switch (value) {
      'ALCISTA' => TrendBreakDirection.alcista,
      'CUALQUIERA' => TrendBreakDirection.cualquiera,
      _ => TrendBreakDirection.bajista,
    };

/// Defaults del producto, iguales a los que aplica el backend cuando el cliente omite el
/// parámetro (`app/services/watchlist_alert_service.py`). Se replican acá para que el formulario
/// arranque mostrando exactamente lo que se va a guardar, en vez de campos vacíos que el servidor
/// completa por su cuenta.
const AlertSeverity kDefaultMinSeverity = AlertSeverity.high;
const TrendHorizon kDefaultTrendHorizon = TrendHorizon.mediano;
const TrendBreakDirection kDefaultTrendDirection = TrendBreakDirection.bajista;
const double kDefaultMinProbabilityPct = 50;
const double kDefaultThresholdPct = 3;

@immutable
class WatchlistAlertRule {
  const WatchlistAlertRule({
    required this.id,
    required this.watchlistItemId,
    required this.ticker,
    required this.alertType,
    required this.enabled,
    required this.thresholdPct,
    required this.minSeverity,
    required this.requireNegativeSentiment,
    required this.trendHorizon,
    required this.trendDirection,
    required this.minProbabilityPct,
  });

  factory WatchlistAlertRule.fromJson(Map<String, dynamic> json) =>
      WatchlistAlertRule(
        id: json['id'] as String,
        watchlistItemId: json['watchlist_item_id'] as String,
        ticker: json['ticker'] as String,
        alertType: alertRuleTypeFromWire(json['alert_type'] as String?),
        enabled: json['enabled'] as bool? ?? true,
        // Los Decimal del backend viajan como string ("6.50"): se parsean desde `toString()` para
        // aceptar también un number, que es lo que devolvería otro serializador.
        thresholdPct: _parseDecimal(json['threshold_pct']),
        minSeverity: json['min_severity'] == null
            ? null
            : alertSeverityFromWire(json['min_severity'] as String?),
        requireNegativeSentiment:
            json['require_negative_sentiment'] as bool? ?? false,
        trendHorizon: json['trend_horizon'] == null
            ? null
            : trendHorizonFromWire(json['trend_horizon'] as String?),
        trendDirection: json['trend_direction'] == null
            ? null
            : trendDirectionFromWire(json['trend_direction'] as String?),
        minProbabilityPct: _parseDecimal(json['min_probability_pct']),
      );

  final String id;
  final String watchlistItemId;
  final String ticker;
  final AlertRuleType alertType;

  /// Apagada sigue existiendo: el usuario que silencia un aviso por una semana no pierde el umbral
  /// que ajustó. Por eso la UI ofrece "apagar" y "eliminar" como acciones distintas.
  final bool enabled;

  final double? thresholdPct;
  final AlertSeverity? minSeverity;
  final bool requireNegativeSentiment;
  final TrendHorizon? trendHorizon;
  final TrendBreakDirection? trendDirection;
  final double? minProbabilityPct;

  /// Resumen de una línea de lo que hace la regla, para mostrarla sin abrir el formulario.
  String get summary => switch (alertType) {
        AlertRuleType.price =>
          'Variación de ±${(thresholdPct ?? kDefaultThresholdPct).toStringAsFixed(1)}%',
        AlertRuleType.newsSeverity => [
            'Severidad ${(minSeverity ?? kDefaultMinSeverity).displayName.toLowerCase()} o mayor',
            if (requireNegativeSentiment) 'solo lectura negativa',
          ].join(' · '),
        AlertRuleType.trendBreak => [
            'Quiebre de ${(trendHorizon ?? kDefaultTrendHorizon).shortName}',
            (trendDirection ?? kDefaultTrendDirection)
                .displayName
                .toLowerCase(),
            '≥ ${(minProbabilityPct ?? kDefaultMinProbabilityPct).toStringAsFixed(0)}%',
          ].join(' · '),
      };
}

double? _parseDecimal(Object? raw) {
  if (raw == null) return null;
  return double.tryParse(raw.toString());
}

/// Lo que la UI quiere guardar, antes de que exista una regla.
///
/// Existe separado de `WatchlistAlertRule` porque el borrador no tiene id ni fechas, y sobre todo
/// porque es el que sabe serializar SOLO los campos de su tipo: el backend rechaza los de otro
/// tipo con 422, y armar el mapa a mano en cada formulario sería repetir esa regla en tres lugares
/// donde se puede olvidar.
@immutable
class WatchlistAlertRuleDraft {
  const WatchlistAlertRuleDraft({
    required this.alertType,
    this.enabled = true,
    this.thresholdPct,
    this.minSeverity,
    this.requireNegativeSentiment,
    this.trendHorizon,
    this.trendDirection,
    this.minProbabilityPct,
  });

  /// Borrador a partir de una regla existente, para abrir el formulario con lo que ya está
  /// guardado.
  factory WatchlistAlertRuleDraft.fromRule(WatchlistAlertRule rule) =>
      WatchlistAlertRuleDraft(
        alertType: rule.alertType,
        enabled: rule.enabled,
        thresholdPct: rule.thresholdPct,
        minSeverity: rule.minSeverity,
        requireNegativeSentiment: rule.requireNegativeSentiment,
        trendHorizon: rule.trendHorizon,
        trendDirection: rule.trendDirection,
        minProbabilityPct: rule.minProbabilityPct,
      );

  /// Borrador nuevo con los defaults del producto ya puestos, para que el formulario muestre desde
  /// el principio lo que se va a guardar.
  factory WatchlistAlertRuleDraft.defaults(
    AlertRuleType alertType, {
    double? currentThresholdPct,
  }) =>
      switch (alertType) {
        // El umbral arranca en el que el usuario YA tiene configurado en su item de watchlist, no
        // en la constante global: quien venía usando 8% no debería encontrarse con un 3%.
        AlertRuleType.price => WatchlistAlertRuleDraft(
            alertType: alertType,
            thresholdPct: currentThresholdPct ?? kDefaultThresholdPct,
          ),
        AlertRuleType.newsSeverity => WatchlistAlertRuleDraft(
            alertType: alertType,
            minSeverity: kDefaultMinSeverity,
            requireNegativeSentiment: false,
          ),
        AlertRuleType.trendBreak => WatchlistAlertRuleDraft(
            alertType: alertType,
            trendHorizon: kDefaultTrendHorizon,
            trendDirection: kDefaultTrendDirection,
            minProbabilityPct: kDefaultMinProbabilityPct,
          ),
      };

  final AlertRuleType alertType;
  final bool enabled;
  final double? thresholdPct;
  final AlertSeverity? minSeverity;
  final bool? requireNegativeSentiment;
  final TrendHorizon? trendHorizon;
  final TrendBreakDirection? trendDirection;
  final double? minProbabilityPct;

  WatchlistAlertRuleDraft copyWith({
    bool? enabled,
    double? thresholdPct,
    AlertSeverity? minSeverity,
    bool? requireNegativeSentiment,
    TrendHorizon? trendHorizon,
    TrendBreakDirection? trendDirection,
    double? minProbabilityPct,
  }) =>
      WatchlistAlertRuleDraft(
        alertType: alertType,
        enabled: enabled ?? this.enabled,
        thresholdPct: thresholdPct ?? this.thresholdPct,
        minSeverity: minSeverity ?? this.minSeverity,
        requireNegativeSentiment:
            requireNegativeSentiment ?? this.requireNegativeSentiment,
        trendHorizon: trendHorizon ?? this.trendHorizon,
        trendDirection: trendDirection ?? this.trendDirection,
        minProbabilityPct: minProbabilityPct ?? this.minProbabilityPct,
      );

  /// Cuerpo de `POST /watchlist/alerts`. Solo los campos del tipo elegido: mandar uno ajeno es un
  /// 422 del backend, a propósito.
  Map<String, dynamic> toCreateJson(String ticker) => {
        'ticker': ticker,
        'alert_type': alertType.wireValue,
        'enabled': enabled,
        ..._typeFields(),
      };

  /// Cuerpo de `PATCH /watchlist/alerts/{id}`. No lleva `ticker` ni `alert_type`: no se pueden
  /// cambiar (eso sería otra regla, y dejaría la fila con los parámetros del tipo anterior).
  Map<String, dynamic> toUpdateJson() => {
        'enabled': enabled,
        ..._typeFields(),
      };

  Map<String, dynamic> _typeFields() => switch (alertType) {
        AlertRuleType.price => {
            if (thresholdPct != null) 'threshold_pct': thresholdPct.toString(),
          },
        AlertRuleType.newsSeverity => {
            if (minSeverity != null) 'min_severity': minSeverity!.wireValue,
            if (requireNegativeSentiment != null)
              'require_negative_sentiment': requireNegativeSentiment,
          },
        AlertRuleType.trendBreak => {
            if (trendHorizon != null) 'trend_horizon': trendHorizon!.wireValue,
            if (trendDirection != null)
              'trend_direction': trendDirection!.wireValue,
            if (minProbabilityPct != null)
              'min_probability_pct': minProbabilityPct.toString(),
          },
      };
}
