import 'package:flutter/foundation.dart';

/// Una vela del histórico. Espeja `OhlcBarOut` (`app/schemas/market.py`), que usa nombres de un
/// solo carácter por convención de las librerías de charting — acá se expanden a nombres legibles,
/// que es lo que corresponde en el modelo de dominio del cliente.
@immutable
class OhlcBar {
  const OhlcBar({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  factory OhlcBar.fromJson(Map<String, dynamic> json) => OhlcBar(
        // El backend manda milisegundos UTC. `isUtc: true` importa: sin eso `DateTime` asume hora
        // local y las etiquetas del eje se corren según la zona del dispositivo.
        time: DateTime.fromMillisecondsSinceEpoch(
          (json['t'] as num).toInt(),
          isUtc: true,
        ),
        open: (json['o'] as num).toDouble(),
        high: (json['h'] as num).toDouble(),
        low: (json['l'] as num).toDouble(),
        close: (json['c'] as num).toDouble(),
        volume: (json['v'] as num).toDouble(),
      );

  final DateTime time;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  /// `close >= open` cuenta como alcista: una vela plana (doji) se pinta en verde en vez de
  /// inventarle un tercer color para un caso que visualmente no aporta.
  bool get isBullish => close >= open;

  @override
  bool operator ==(Object other) =>
      other is OhlcBar &&
      other.time == time &&
      other.open == open &&
      other.high == high &&
      other.low == low &&
      other.close == close &&
      other.volume == volume;

  @override
  int get hashCode => Object.hash(time, open, high, low, close, volume);
}

/// Respuesta de `GET /api/v1/market/history/{ticker}`.
///
/// `bars` vacío con HTTP 200 es una respuesta válida y esperada: el proveedor puede estar caído,
/// sin configurar, o el rango puede no tener ruedas. `degradationReason` dice cuál fue, así el
/// chart muestra el motivo en vez de un rectángulo en blanco.
@immutable
class TickerHistory {
  const TickerHistory({
    required this.ticker,
    required this.start,
    required this.end,
    required this.bars,
    required this.degradationReason,
  });

  factory TickerHistory.fromJson(Map<String, dynamic> json) => TickerHistory(
        ticker: json['ticker'] as String,
        start: DateTime.parse(json['start'] as String),
        end: DateTime.parse(json['end'] as String),
        bars: [
          for (final bar in json['bars'] as List)
            OhlcBar.fromJson(bar as Map<String, dynamic>),
        ],
        degradationReason: json['degradation_reason'] as String?,
      );

  final String ticker;
  final DateTime start;
  final DateTime end;
  final List<OhlcBar> bars;
  final String? degradationReason;

  bool get isEmpty => bars.isEmpty;

  /// Rango de precios de todo el histórico, para escalar el eje Y. `null` si no hay velas.
  ///
  /// Se calcula sobre `low`/`high` y no sobre los cierres: usar solo los cierres recortaría las
  /// mechas fuera del área visible, que es justo la información que una vela aporta.
  ({double min, double max})? get priceRange {
    if (bars.isEmpty) return null;
    var min = bars.first.low;
    var max = bars.first.high;
    for (final bar in bars.skip(1)) {
      if (bar.low < min) min = bar.low;
      if (bar.high > max) max = bar.high;
    }
    return (min: min, max: max);
  }
}
