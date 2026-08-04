import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_theme.dart';
import '../data/ohlc_data.dart';

/// Chart de velas OHLC, dibujado con `fl_chart` — Flutter puro, sin WebView ni CDN.
///
/// Reemplaza la versión anterior basada en `webview_flutter` + Lightweight Charts, que tenía dos
/// problemas de fondo: `webview_flutter` solo declara android/ios/macos (en Web, Linux y Windows
/// pintaba un bloque gris sin estilo), y la librería JS se bajaba de unpkg en cada arranque. Este
/// widget se renderiza igual en todas las plataformas y no toca la red.
class CandlestickChartView extends StatelessWidget {
  const CandlestickChartView({super.key, required this.bars});

  final List<OhlcBar> bars;

  /// Cuántas etiquetas de fecha caben en el eje X. Con 30 velas en un panel de 380px, una etiqueta
  /// por vela se superpone hasta ser ilegible: se muestran ~5 y el resto queda implícito.
  static const int _maxDateLabels = 5;

  @override
  Widget build(BuildContext context) {
    if (bars.isEmpty) return const SizedBox.shrink();

    final range = _paddedRange();

    return CandlestickChart(
      CandlestickChartData(
        candlestickSpots: [
          for (var i = 0; i < bars.length; i++)
            CandlestickSpot(
              // El índice como X (no el timestamp): así los fines de semana y feriados no dejan
              // huecos vacíos en el eje, que es la convención de cualquier chart financiero.
              x: i.toDouble(),
              open: bars[i].open,
              high: bars[i].high,
              low: bars[i].low,
              close: bars[i].close,
            ),
        ],
        minY: range.min,
        maxY: range.max,
        candlestickPainter: DefaultCandlestickPainter(
          candlestickStyleProvider: (spot, index) => _styleFor(bars[index]),
        ),
        gridData: FlGridData(
          drawVerticalLine: false,
          horizontalInterval: (range.max - range.min) / 4,
          getDrawingHorizontalLine: (value) =>
              const FlLine(color: AppTheme.border, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 52,
              interval: (range.max - range.min) / 4,
              // Sin las etiquetas de los extremos: `minY`/`maxY` llevan el 5% de margen
              // artificial, así que esos dos valores no son precios reales del histórico — y
              // encima chocaban con la etiqueta de la grilla vecina.
              minIncluded: false,
              maxIncluded: false,
              getTitlesWidget: _priceLabel,
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 26,
              interval: _dateLabelInterval(),
              // La última fecha se dibujaría pegada al borde derecho, cortada a la mitad.
              maxIncluded: false,
              getTitlesWidget: _dateLabel,
            ),
          ),
        ),
        candlestickTouchData: CandlestickTouchData(
          touchTooltipData: CandlestickTouchTooltipData(
            getTooltipColor: (spot) => AppTheme.surfaceSunken,
            tooltipBorderRadius: BorderRadius.circular(AppTheme.radius),
            tooltipBorder: const BorderSide(color: AppTheme.border),
            // Ancho suficiente para que las líneas de OHLC no se corten al medio: con el default
            // el tooltip envolvía "A 651.04   M 658.34" en dos renglones.
            maxContentWidth: 200,
            // Cerca del borde derecho el tooltip se saldría del chart; esto lo corre adentro.
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            getTooltipItems: _tooltip,
          ),
        ),
        // Cruz de acento sobre la vela tocada: ubica el precio en el eje sin tener que leer el
        // tooltip. Los "providers" reciben la coordenada y devuelven la línea, lo que permitiría
        // variarla por posición; acá es constante.
        touchedPointIndicator: AxisSpotIndicator(
          painter: AxisLinesIndicatorPainter(
            verticalLineProvider: (x) =>
                VerticalLine(x: x, color: AppTheme.accent, strokeWidth: 1),
            horizontalLineProvider: (y) =>
                HorizontalLine(y: y, color: AppTheme.accent, strokeWidth: 1),
          ),
        ),
      ),
    );
  }

  /// Rango del eje Y con un 5% de aire arriba y abajo. Sin ese margen, la vela más alta y la más
  /// baja quedan pegadas al borde y se leen como recortadas.
  ({double min, double max}) _paddedRange() {
    var min = bars.first.low;
    var max = bars.first.high;
    for (final bar in bars.skip(1)) {
      if (bar.low < min) min = bar.low;
      if (bar.high > max) max = bar.high;
    }
    // Un histórico completamente plano daría span 0 y una división por cero al calcular los
    // intervalos de la grilla: se le da un rango artificial mínimo.
    final span = max - min;
    if (span <= 0) {
      final pad = max.abs() * 0.01 + 1;
      return (min: min - pad, max: max + pad);
    }
    final pad = span * 0.05;
    return (min: min - pad, max: max + pad);
  }

  CandlestickStyle _styleFor(OhlcBar bar) {
    final color = bar.isBullish ? AppTheme.bullish : AppTheme.bearish;
    return CandlestickStyle(
      lineColor: color,
      lineWidth: 1,
      bodyFillColor: color,
      bodyStrokeColor: color,
      bodyStrokeWidth: 1,
      bodyWidth: 6,
      bodyRadius: 1,
    );
  }

  double _dateLabelInterval() {
    final interval = (bars.length / _maxDateLabels).ceilToDouble();
    // `interval` nunca puede ser 0: fl_chart lanza si el intervalo de un eje es cero o negativo.
    return interval < 1 ? 1 : interval;
  }

  static Widget _priceLabel(double value, TitleMeta meta) {
    // Sin decimales cuando el precio ya es grande: "951" contra "951.30" ahorra ancho en el eje
    // sin perder información útil a esta escala.
    final text = value.abs() >= 100
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(2);
    return SideTitleWidget(
      meta: meta,
      child: Text(text, style: AppTheme.numeric(fontSize: 10)),
    );
  }

  Widget _dateLabel(double value, TitleMeta meta) {
    final index = value.round();
    if (index < 0 || index >= bars.length) return const SizedBox.shrink();
    return SideTitleWidget(
      meta: meta,
      child: Text(
        DateFormat('dd/MM').format(bars[index].time),
        style: AppTheme.numeric(fontSize: 10),
      ),
    );
  }

  /// `fl_chart` llama esto con UNA vela por vez (la tocada), no con la lista entera.
  CandlestickTooltipItem? _tooltip(
    FlCandlestickPainter painter,
    CandlestickSpot spot,
    int spotIndex,
  ) {
    if (spotIndex < 0 || spotIndex >= bars.length) return null;
    return _tooltipItem(bars[spotIndex]);
  }

  CandlestickTooltipItem _tooltipItem(OhlcBar bar) {
    final color = bar.isBullish ? AppTheme.bullish : AppTheme.bearish;
    final change =
        bar.open == 0 ? null : (bar.close - bar.open) / bar.open * 100;
    final changeLabel = change == null
        ? ''
        : '  ${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}%';

    // Apertura / Máximo / mínimo / Cierre, alineados en dos columnas. La monoespaciada del tema
    // es lo que hace que los precios queden en la misma coordenada renglón a renglón.
    return CandlestickTooltipItem(
      '${DateFormat('dd/MM/yyyy').format(bar.time)}$changeLabel\n'
      'A ${_price(bar.open)}  M ${_price(bar.high)}\n'
      'm ${_price(bar.low)}  C ${_price(bar.close)}',
      textStyle: AppTheme.numeric(fontSize: 11, color: color),
    );
  }

  static String _price(double value) => value.toStringAsFixed(2);
}
