import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../corporate/data/corporate_formatting.dart';
import 'portfolio_builder_models.dart';

/// Formato y color propios del Constructor de Portafolios.
///
/// El resto reutiliza `corporate_formatting.dart`: los mismos montos de las mismas empresas se ven
/// igual vengan de donde vengan. Lo que se agrega acá es lo que ese módulo no tiene — montos de
/// cartera con separador de miles, y la paleta de las porciones de la torta.

/// Monto en dólares con separador de miles rioplatense: `US$ 12.500,00`.
///
/// `formatRevenue` del Hub no sirve para esto: abrevia a millones (`US$ 130,50 MM`), que es lo
/// correcto para un balance y lo inútil para una cartera de US$ 12.500.
String formatUsd(double? value) {
  if (value == null) return kMissingValue;
  final negative = value < 0;
  final parts = value.abs().toStringAsFixed(2).split('.');
  final digits = parts[0];

  final buffer = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) buffer.write('.');
    buffer.write(digits[index]);
  }
  return '${negative ? "−" : ""}US\$ $buffer,${parts[1]}';
}

/// Monto sin decimales, para las etiquetas donde los centavos son ruido.
String formatUsdCompact(double? value) {
  if (value == null) return kMissingValue;
  return formatUsd(value.roundToDouble()).replaceAll(',00', '');
}

/// Un porcentaje de cartera: un NIVEL, sin signo adelante.
String formatWeightPct(double? value) =>
    value == null ? kMissingValue : formatSurprisePct(value).replaceAll('+', '');

/// El índice de Herfindahl con coma decimal.
///
/// `toStringAsFixed` devuelve punto y el resto de la app usa coma: "0.72" al lado de "82,9%" se lee
/// como si vinieran de dos sistemas distintos.
String formatHerfindahl(double? value, {int decimals = 2}) => value == null
    ? kMissingValue
    : value.toStringAsFixed(decimals).replaceAll('.', ',');

/// Color del badge de riesgo.
///
/// La escala va de acento (baja) a bajista (crítica) y **no usa verde**: un "riesgo bajo" en verde se
/// leería como una recomendación, y la concentración no dice nada sobre si la cartera es buena.
Color riskColor(RiskLevel level) => switch (level) {
      RiskLevel.baja => AppTheme.accent,
      RiskLevel.moderada => AppTheme.neutral,
      RiskLevel.alta => const Color(0xFFFB923C),
      RiskLevel.critica => AppTheme.bearish,
    };

IconData riskIcon(RiskLevel level) => switch (level) {
      RiskLevel.baja => Icons.check_circle_outline,
      RiskLevel.moderada => Icons.info_outline,
      RiskLevel.alta => Icons.warning_amber_outlined,
      RiskLevel.critica => Icons.dangerous_outlined,
    };

/// Qué mide el nivel, en una línea. Va al lado del badge porque "riesgo alto" sin decir de qué se
/// leería como un juicio sobre los activos elegidos, y es sobre el REPARTO.
String riskCaption(RiskLevel level) => switch (level) {
      RiskLevel.baja => 'El capital está repartido entre varios sectores.',
      RiskLevel.moderada => 'Hay un sector que empieza a dominar el reparto.',
      RiskLevel.alta => 'Un sector concentra buena parte del capital.',
      RiskLevel.critica => 'Casi todo el capital depende de un mismo sector.',
    };

/// Paleta de las porciones de la torta.
///
/// Son tonos distinguibles entre sí y ninguno es el verde/rojo del tema: esos dos significan "subió"
/// y "bajó" en toda la app, y usarlos para identificar un activo haría que una porción roja pareciera
/// una posición perdedora.
const List<Color> kSliceColors = [
  Color(0xFF22D3EE),
  Color(0xFF818CF8),
  Color(0xFFF472B6),
  Color(0xFFFBBF24),
  Color(0xFF2DD4BF),
  Color(0xFFA78BFA),
  Color(0xFF60A5FA),
  Color(0xFFFB923C),
  Color(0xFF34D399),
  Color(0xFFE879F9),
];

/// Color estable para la porción `index`. Se cicla la paleta cuando hay más posiciones que colores:
/// dos porciones del mismo color en una cartera de doce es preferible a un color calculado que puede
/// caer sobre el fondo.
Color sliceColor(int index) => kSliceColors[index % kSliceColors.length];
