import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../data/corporate_formatting.dart';
import '../data/corporate_models.dart';
import 'corporate_badges.dart';

/// Barras de sorpresa por trimestre: cuánto se desvió el EPS reportado del estimado.
///
/// Es un gráfico de barras con línea de cero y no una serie de líneas: cada trimestre es un evento
/// discreto e independiente, y unirlos con una línea sugeriría una tendencia continua entre
/// mediciones que están a tres meses una de otra.
///
/// **Solo entran los trimestres con porcentaje calculado.** Un trimestre sin estimación previa, o con
/// una base demasiado chica para que el cociente signifique algo, no tiene barra — dibujarlo con
/// altura cero lo mostraría como "reportó exactamente lo esperado", que es otra afirmación. Cuántos
/// quedaron afuera se dice en texto debajo del gráfico.
class SurpriseChart extends StatelessWidget {
  const SurpriseChart({super.key, required this.quarters, this.height = 140});

  /// Del más reciente al más viejo, como los devuelve el backend.
  final List<EarningsEvent> quarters;

  final double height;

  @override
  Widget build(BuildContext context) {
    // Se invierte para dibujar de izquierda (más viejo) a derecha (más reciente): el eje temporal de
    // un gráfico se lee así, aunque la lista de abajo esté ordenada al revés.
    final plotted = quarters.reversed
        .where((quarter) => quarter.epsSurprisePct != null)
        .toList(growable: false);

    final omitted = quarters.length - plotted.length;

    if (plotted.isEmpty) {
      return Container(
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppTheme.surfaceSunken,
          borderRadius: BorderRadius.circular(AppTheme.radius),
          border: Border.all(color: AppTheme.border),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: const Text(
          'Ningún trimestre tiene un porcentaje de sorpresa calculable: '
          'faltan las estimaciones previas o la base era demasiado chica.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: height,
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
          decoration: BoxDecoration(
            color: AppTheme.surfaceSunken,
            borderRadius: BorderRadius.circular(AppTheme.radius),
            border: Border.all(color: AppTheme.border),
          ),
          child: CustomPaint(
            painter: _SurpriseBarsPainter(quarters: plotted),
            // El `child` vacío con tamaño infinito es lo que le da al painter todo el espacio del
            // contenedor: sin él, `CustomPaint` se dimensiona en cero dentro de un Column.
            child: const SizedBox.expand(),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const _LegendDot(color: AppTheme.bullish, label: 'Superó'),
            const SizedBox(width: 12),
            const _LegendDot(color: AppTheme.bearish, label: 'Falló'),
            const SizedBox(width: 12),
            const _LegendDot(color: AppTheme.accent, label: 'En línea'),
            const Spacer(),
            if (omitted > 0)
              Flexible(
                child: Text(
                  '$omitted sin % calculable',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textMuted)),
      ],
    );
  }
}

class _SurpriseBarsPainter extends CustomPainter {
  _SurpriseBarsPainter({required this.quarters});

  /// Ya filtrados (todos tienen `epsSurprisePct`) y en orden cronológico.
  final List<EarningsEvent> quarters;

  /// Escala mínima del eje, en puntos porcentuales. Sin un piso, un trimestre con +0,3% de sorpresa
  /// se dibujaría como una barra que toca el techo y se leería como un resultado enorme.
  static const double _minScalePct = 5;

  /// Ancho máximo de la ranura de cada trimestre. Con menos trimestres que ranuras disponibles, el
  /// grupo se centra en vez de estirarse hasta los bordes.
  static const double _maxSlotWidth = 90;

  @override
  void paint(Canvas canvas, Size size) {
    if (quarters.isEmpty || size.width <= 0 || size.height <= 0) return;

    final maxAbs = quarters
        .map((quarter) => quarter.epsSurprisePct!.abs())
        .reduce((a, b) => a > b ? a : b);
    final scale = maxAbs < _minScalePct ? _minScalePct : maxAbs;

    // Espacio reservado abajo para las etiquetas de fecha, para que las barras negativas no las
    // pisen.
    const labelBand = 14.0;
    final plotHeight = size.height - labelBand;
    final zeroY = plotHeight / 2;

    final zeroPaint = Paint()
      ..color = AppTheme.border
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, zeroY), Offset(size.width, zeroY), zeroPaint);

    // La ranura por trimestre está topeada y el grupo se CENTRA: sin el tope, tres trimestres se
    // reparten mil pixeles y quedan tres barras flotando en las esquinas, que no se lee como una
    // serie. Con el tope, pocos trimestres forman un grupo compacto en el medio y muchos usan todo
    // el ancho disponible.
    final slot = (size.width / quarters.length).clamp(0.0, _maxSlotWidth);
    final offsetX = (size.width - slot * quarters.length) / 2;
    final barWidth = (slot * 0.5).clamp(6.0, 28.0);

    for (var index = 0; index < quarters.length; index++) {
      final quarter = quarters[index];
      final pct = quarter.epsSurprisePct!;
      final centerX = offsetX + slot * index + slot / 2;
      final magnitude = (pct.abs() / scale) * (zeroY - 4);
      // Altura mínima visible: una sorpresa de +0,05% existe y tiene que verse como una marca, no
      // desaparecer contra la línea de cero.
      final barHeight = magnitude < 2 ? 2.0 : magnitude;

      final rect = Rect.fromLTWH(
        centerX - barWidth / 2,
        pct >= 0 ? zeroY - barHeight : zeroY,
        barWidth,
        barHeight,
      );

      canvas.drawRRect(
        RRect.fromRectAndCorners(
          rect,
          topLeft: Radius.circular(pct >= 0 ? 3 : 0),
          topRight: Radius.circular(pct >= 0 ? 3 : 0),
          bottomLeft: Radius.circular(pct >= 0 ? 0 : 3),
          bottomRight: Radius.circular(pct >= 0 ? 0 : 3),
        ),
        Paint()..color = surpriseDirectionColor(quarter.surpriseDirection),
      );

      _paintLabel(
        canvas,
        text: formatCalendarDay(quarter.eventDate).split(' ').last,
        center: Offset(centerX, plotHeight + labelBand / 2 + 1),
        maxWidth: slot,
      );
    }
  }

  void _paintLabel(
    Canvas canvas, {
    required String text,
    required Offset center,
    required double maxWidth,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          fontFamily: 'AppMono',
          fontSize: 9,
          color: AppTheme.textMuted,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // Si la etiqueta no cabe en su ranura se omite en vez de superponerse con la vecina: dos fechas
    // encimadas no se pueden leer, y una barra sin fecha sigue mostrando la magnitud.
    if (painter.width > maxWidth - 2) return;

    painter.paint(
      canvas,
      Offset(center.dx - painter.width / 2, center.dy - painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(_SurpriseBarsPainter oldDelegate) =>
      oldDelegate.quarters != quarters;
}
