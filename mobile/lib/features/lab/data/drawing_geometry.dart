import 'dart:ui';

import 'note_attachment.dart';

/// Conversión entre las coordenadas normalizadas (0..1) de la capa de dibujo y los píxeles de la
/// pantalla.
///
/// Existe como pieza aparte —y no como un par de métodos adentro del painter— porque la misma
/// conversión la necesitan tres lugares que TIENEN que coincidir exactamente: el painter que dibuja
/// las anotaciones, el detector de gestos que convierte el dedo del usuario en un punto normalizado,
/// y la miniatura del Lab. Si cada uno hiciera su cuenta, un trazo aparecería unos píxeles corrido
/// respecto de donde se dibujó, y el desfasaje solo se notaría al cambiar el tamaño de la ventana.
///
/// **La conversión NO usa el tamaño del widget: usa el rectángulo real de la imagen adentro.** Con
/// `BoxFit.contain` una captura apaisada dentro de un contenedor cuadrado deja bandas arriba y
/// abajo, y mapear 0..1 sobre el widget entero pondría una flecha que marca un máximo de precio en
/// medio de la banda negra.
class DrawingGeometry {
  const DrawingGeometry(this.imageRect);

  /// El rectángulo que ocupa la imagen dentro del widget, ya descontadas las bandas del `contain`.
  final Rect imageRect;

  /// Calcula el rectángulo de la imagen para un widget de [size].
  ///
  /// [aspectRatio] es ancho/alto de la imagen. Cuando es `null` (el backend no conoce las
  /// dimensiones) se asume que la imagen llena el widget: es lo mismo que hace `BoxFit.fill`, y es
  /// el único supuesto que no desplaza nada cuando además se dibuja con ese fit.
  factory DrawingGeometry.contain(Size size, double? aspectRatio) {
    if (aspectRatio == null || aspectRatio <= 0 || !aspectRatio.isFinite) {
      return DrawingGeometry(Offset.zero & size);
    }
    if (size.width <= 0 || size.height <= 0) {
      return DrawingGeometry(Offset.zero & size);
    }

    final widgetRatio = size.width / size.height;
    if (widgetRatio > aspectRatio) {
      // El widget es más ancho que la imagen: sobran bandas a los costados.
      final width = size.height * aspectRatio;
      return DrawingGeometry(
        Rect.fromLTWH((size.width - width) / 2, 0, width, size.height),
      );
    }
    // El widget es más alto: sobran bandas arriba y abajo.
    final height = size.width / aspectRatio;
    return DrawingGeometry(
      Rect.fromLTWH(0, (size.height - height) / 2, size.width, height),
    );
  }

  /// De coordenada normalizada a píxel.
  Offset toPixels(NormalizedPoint point) => Offset(
        imageRect.left + point.x * imageRect.width,
        imageRect.top + point.y * imageRect.height,
      );

  /// De píxel (posición local del gesto dentro del widget) a coordenada normalizada.
  ///
  /// El recorte lo hace [NormalizedPoint]: un dedo que se sale de la imagen produce el borde, no un
  /// valor inválido que el backend rechazaría con 422 después de todo el trazo.
  NormalizedPoint toNormalized(Offset pixel) {
    if (imageRect.width <= 0 || imageRect.height <= 0) {
      return NormalizedPoint(0, 0);
    }
    return NormalizedPoint(
      (pixel.dx - imageRect.left) / imageRect.width,
      (pixel.dy - imageRect.top) / imageRect.height,
    );
  }

  /// Cuánto hay que escalar el grosor de un trazo.
  ///
  /// El grosor se guarda en píxeles lógicos pensados sobre la imagen a tamaño natural. Sin escalar,
  /// una línea de 3px trazada en el editor a pantalla completa se vería igual de gruesa en una
  /// miniatura de 120px, tapando el gráfico entero. Se toma el ancho como referencia porque el
  /// `contain` preserva la proporción: escalar por ancho y por alto daría el mismo factor.
  double strokeScale(double? referenceWidth) {
    if (referenceWidth == null || referenceWidth <= 0) return 1;
    final scale = imageRect.width / referenceWidth;
    // Piso para que un trazo nunca desaparezca en una miniatura muy chica: una anotación invisible
    // es indistinguible de una que no se guardó.
    return scale.clamp(0.25, 4.0);
  }

  @override
  bool operator ==(Object other) =>
      other is DrawingGeometry && other.imageRect == imageRect;

  @override
  int get hashCode => imageRect.hashCode;
}
