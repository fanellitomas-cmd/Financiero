import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart' show GlobalKey;

/// Captura de un widget ya renderizado a PNG.
///
/// El gráfico del que se saca la captura es el MISMO que el usuario está mirando: no se re-dibuja en
/// un canvas aparte con los datos. Rehacerlo significaría mantener dos renders del chart en sincronía
/// y que la captura pueda diferir de lo que había en pantalla — justo lo que una nota de análisis
/// técnico no puede permitirse.

@immutable
class ChartSnapshot {
  const ChartSnapshot({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;

  /// Dimensiones en píxeles REALES del PNG (ya multiplicadas por el `pixelRatio`), no las lógicas
  /// del widget. Son las que el backend guarda y con las que el editor calcula la proporción: usar
  /// las lógicas dejaría las anotaciones estiradas en una pantalla retina.
  final int width;
  final int height;

  double get aspectRatio => height == 0 ? 1 : width / height;
}

/// Rasteriza el `RepaintBoundary` de [key].
///
/// Devuelve `null` en vez de lanzar cuando el boundary todavía no pintó o el widget se desmontó
/// entre el toque y la captura: es una condición esperable (el usuario tocó "exportar" mientras el
/// chart estaba cargando), y un error acá se convertiría en un crash por algo que la UI puede
/// explicar con un aviso.
///
/// [pixelRatio] 2.0 y no el de la pantalla: una captura de chart se vuelve a mirar meses después y
/// conviene que las velas finas se lean, pero el 3.0 de un teléfono moderno cuadruplicaría el peso
/// de cada adjunto sin que se note la diferencia dentro de una nota.
Future<ChartSnapshot?> captureBoundary(
  GlobalKey key, {
  double pixelRatio = 2.0,
}) async {
  final object = key.currentContext?.findRenderObject();
  if (object is! RenderRepaintBoundary) return null;

  // `debugNeedsPaint` es la condición real de fallo: `toImage` sobre un boundary sucio lanza en
  // modo debug y devuelve un frame viejo en release. Preguntarlo es más honesto que capturar la
  // excepción después.
  if (kDebugMode && object.debugNeedsPaint) return null;

  ui.Image? image;
  try {
    image = await object.toImage(pixelRatio: pixelRatio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return null;
    return ChartSnapshot(
      bytes: data.buffer.asUint8List(),
      width: image.width,
      height: image.height,
    );
  } on Object {
    // El caso conocido es el boundary sin pintar; cualquier otro fallo del motor gráfico llega acá
    // igual y se resuelve con el mismo aviso, que es mejor que un crash.
    return null;
  } finally {
    // `ui.Image` es un recurso nativo: sin `dispose` cada captura filtra los megabytes del bitmap
    // hasta que el GC decide correr.
    image?.dispose();
  }
}
