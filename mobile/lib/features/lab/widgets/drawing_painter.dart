import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../data/drawing_geometry.dart';
import '../data/note_attachment.dart';

/// Pinta la capa de anotaciones encima de una captura.
///
/// El mismo painter se usa en el editor a pantalla completa y en la miniatura del Lab: el trazo se
/// ve idéntico en los dos porque toda la conversión pasa por [DrawingGeometry], que mapea las
/// coordenadas 0..1 al rectángulo REAL de la imagen (no al del widget). Dos painters distintos
/// terminarían dibujando la misma flecha en dos lugares apenas distintos.
class DrawingPainter extends CustomPainter {
  const DrawingPainter({
    required this.shapes,
    required this.aspectRatio,
    this.referenceWidth,
    this.textScale = 1,
  });

  final List<DrawingShape> shapes;

  /// Ancho/alto de la imagen de fondo. `null` = la imagen llena el widget.
  final double? aspectRatio;

  /// Ancho en píxeles para el que se pensaron los grosores. Cuando viene, el trazo se escala con el
  /// tamaño mostrado: una línea de 3px dibujada a pantalla completa se afina en la miniatura en vez
  /// de taparla.
  final double? referenceWidth;

  final double textScale;

  @override
  void paint(Canvas canvas, Size size) {
    final geometry = DrawingGeometry.contain(size, aspectRatio);
    if (geometry.imageRect.isEmpty) return;
    final scale = geometry.strokeScale(referenceWidth);

    // Se recorta al rectángulo de la imagen: un trazo cuyo punto quedó justo en el borde no puede
    // derramarse sobre las bandas del `contain` ni sobre el resto de la tarjeta.
    canvas.save();
    canvas.clipRect(geometry.imageRect);

    for (final shape in shapes) {
      // Una forma que no se puede dibujar se saltea en vez de romper el frame: puede venir de una
      // versión del formato que este cliente no conoce.
      if (!shape.isDrawable) continue;
      _paintShape(canvas, geometry, shape, scale);
    }

    canvas.restore();
  }

  void _paintShape(
    Canvas canvas,
    DrawingGeometry geometry,
    DrawingShape shape,
    double scale,
  ) {
    final paint = Paint()
      ..color = shape.color
      ..strokeWidth = math.max(shape.strokeWidth * scale, 0.6)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      // Sin antialias, una diagonal sobre un gráfico de velas se ve escalonada y compite
      // visualmente con las propias velas.
      ..isAntiAlias = true;

    final points = [for (final point in shape.points) geometry.toPixels(point)];

    switch (shape.kind) {
      case ShapeKind.line:
        canvas.drawLine(points[0], points[1], paint);
      case ShapeKind.arrow:
        _paintArrow(canvas, points[0], points[1], paint, scale);
      case ShapeKind.rect:
        canvas.drawRect(Rect.fromPoints(points[0], points[1]), paint);
      case ShapeKind.ellipse:
        canvas.drawOval(Rect.fromPoints(points[0], points[1]), paint);
      case ShapeKind.freehand:
        final path = Path()..moveTo(points.first.dx, points.first.dy);
        for (final point in points.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(path, paint);
      case ShapeKind.text:
        _paintText(canvas, geometry, points.first, shape, scale);
    }
  }

  /// Flecha: el segmento más dos barbas en la punta.
  ///
  /// La cabeza escala con el grosor y no con el largo del trazo: una flecha corta y una larga del
  /// mismo grosor tienen que tener la misma punta, si no una marca corta sobre una vela parece otra
  /// herramienta.
  void _paintArrow(
    Canvas canvas,
    Offset from,
    Offset to,
    Paint paint,
    double scale,
  ) {
    canvas.drawLine(from, to, paint);

    final delta = to - from;
    if (delta.distance < 0.5) return;

    final angle = math.atan2(delta.dy, delta.dx);
    // 9x el grosor: con un múltiplo chico la punta queda de unos pocos píxeles sobre una captura
    // escalada y la flecha se lee como una línea cualquiera — que es justo lo que el usuario NO
    // eligió al tomar la herramienta. Se acota al 40% del propio trazo para que una marca corta no
    // sea toda punta.
    final headLength = math.min(
      math.max(paint.strokeWidth * 9, 12.0 * scale),
      delta.distance * 0.4,
    );
    const spread = math.pi / 7;

    for (final side in [angle - spread, angle + spread]) {
      canvas.drawLine(
        to,
        to - Offset(math.cos(side), math.sin(side)) * headLength,
        paint,
      );
    }
  }

  void _paintText(
    Canvas canvas,
    DrawingGeometry geometry,
    Offset anchor,
    DrawingShape shape,
    double scale,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: shape.text,
        style: TextStyle(
          // La fuente sale de las bundleadas de la app: en Web, un `fontFamily` sin declarar hace
          // que CanvasKit intente bajar "Roboto" y el texto quede invisible sin ningún error.
          fontFamily: 'AppSans',
          fontSize: math.max(13 * scale * textScale, 8),
          fontWeight: FontWeight.w600,
          color: shape.color,
          // Sombra oscura detrás: la anotación se lee sobre una vela verde clara igual que sobre el
          // fondo oscuro del chart, sin tener que elegir un color que contraste con las dos.
          shadows: const [
            Shadow(color: Color(0xCC0B0F19), blurRadius: 3, offset: Offset(0, 1)),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: geometry.imageRect.width);

    // El ancla es la esquina superior izquierda, pero se corre para que una etiqueta puesta cerca
    // del borde derecho o inferior no quede cortada por el clip.
    final dx = math.min(anchor.dx, geometry.imageRect.right - painter.width);
    final dy = math.min(anchor.dy, geometry.imageRect.bottom - painter.height);
    painter.paint(
      canvas,
      Offset(
        math.max(dx, geometry.imageRect.left),
        math.max(dy, geometry.imageRect.top),
      ),
    );
  }

  @override
  bool shouldRepaint(DrawingPainter oldDelegate) =>
      oldDelegate.aspectRatio != aspectRatio ||
      oldDelegate.referenceWidth != referenceWidth ||
      oldDelegate.textScale != textScale ||
      // Comparación por lista y no por identidad: el editor reconstruye la lista en cada trazo, y
      // comparar referencias repintaría siempre (o nunca, si mutara la misma lista in-place).
      !listEquals(oldDelegate.shapes, shapes);
}
