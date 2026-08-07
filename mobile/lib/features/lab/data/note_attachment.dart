/// Modelos de `/api/v1/notes/{id}/attachments` — capturas de gráficos y su capa de dibujo.
///
/// Espejan `app/schemas/note_attachment.py`. Las dos reglas del contrato, que acá se hacen cumplir
/// por construcción:
///
///   1. **Las coordenadas son NORMALIZADAS (0..1), nunca píxeles.** [NormalizedPoint] recorta en el
///      constructor, así que es imposible construir un punto fuera de rango — que el backend
///      rechazaría con 422 después de que el usuario ya dibujó el trazo. La conversión a píxeles
///      vive en un solo lugar ([DrawingGeometry]) y depende del rectángulo REAL de la imagen, no del
///      tamaño del widget.
///   2. **Cada herramienta tiene su aridad.** Una recta con un punto o un texto vacío son un 422 del
///      backend; [DrawingShape.isDrawable] deja detectarlo antes de mandar y de dibujar.
library;

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

/// Herramientas del canvas. Los nombres del wire son los de `ShapeKind` en el backend.
enum ShapeKind { line, arrow, rect, ellipse, freehand, text }

extension ShapeKindWire on ShapeKind {
  String get wireValue => switch (this) {
        ShapeKind.line => 'LINE',
        ShapeKind.arrow => 'ARROW',
        ShapeKind.rect => 'RECT',
        ShapeKind.ellipse => 'ELLIPSE',
        ShapeKind.freehand => 'FREEHAND',
        ShapeKind.text => 'TEXT',
      };

  String get displayName => switch (this) {
        ShapeKind.line => 'Línea',
        ShapeKind.arrow => 'Flecha',
        ShapeKind.rect => 'Rectángulo',
        ShapeKind.ellipse => 'Elipse',
        ShapeKind.freehand => 'Trazo libre',
        ShapeKind.text => 'Texto',
      };

  /// Cuántos puntos necesita la forma. `null` = variable (el trazo libre).
  ///
  /// Es la misma tabla que valida el backend. Se replica acá para poder rechazar un trazo imposible
  /// ANTES de mandarlo: enterarse por un 422 después de dibujar es enterarse tarde.
  int? get requiredPoints => switch (this) {
        ShapeKind.line || ShapeKind.arrow => 2,
        ShapeKind.rect || ShapeKind.ellipse => 2,
        ShapeKind.text => 1,
        ShapeKind.freehand => null,
      };
}

/// `line` como fallback: es la herramienta más simple, así que una forma de un tipo que este cliente
/// no conoce se dibuja como una recta en vez de romper el canvas entero.
ShapeKind shapeKindFromWire(String? value) => switch (value) {
      'ARROW' => ShapeKind.arrow,
      'RECT' => ShapeKind.rect,
      'ELLIPSE' => ShapeKind.ellipse,
      'FREEHAND' => ShapeKind.freehand,
      'TEXT' => ShapeKind.text,
      _ => ShapeKind.line,
    };

/// Un punto en coordenadas relativas a la imagen: (0,0) arriba a la izquierda, (1,1) abajo a la
/// derecha.
///
/// **Se recorta en el constructor.** Un dedo que se va del borde de la imagen mientras dibuja
/// produciría un 1.03 que el backend rechaza con 422 — y el usuario perdería el trazo entero por
/// haberse pasado dos píxeles. Recortar conserva la intención y respeta el contrato.
@immutable
class NormalizedPoint {
  NormalizedPoint(double x, double y)
      : x = x.isFinite ? x.clamp(0.0, 1.0) : 0.0,
        y = y.isFinite ? y.clamp(0.0, 1.0) : 0.0;

  factory NormalizedPoint.fromJson(Map<String, dynamic> json) => NormalizedPoint(
        (json['x'] as num?)?.toDouble() ?? 0,
        (json['y'] as num?)?.toDouble() ?? 0,
      );

  final double x;
  final double y;

  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  @override
  bool operator ==(Object other) =>
      other is NormalizedPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() =>
      'NormalizedPoint(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)})';
}

/// Convierte un `Color` al `#aarrggbb` que espera el backend.
///
/// Se emite SIEMPRE con alfa, aunque sea opaco: un resaltado semitransparente y un trazo sólido son
/// dos herramientas distintas del editor, y perder el canal al guardar convertiría uno en el otro.
String colorToHex(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0')}';

/// Parsea `#rrggbb` o `#aarrggbb`. Devuelve `null` si no es ninguno de los dos.
Color? hexToColor(String? value) {
  if (value == null) return null;
  final hex = value.startsWith('#') ? value.substring(1) : value;
  if (hex.length != 6 && hex.length != 8) return null;
  final parsed = int.tryParse(hex, radix: 16);
  if (parsed == null) return null;
  // Un `#rrggbb` sin alfa es opaco: es la convención de CSS y la que usa el resto del contrato.
  return Color(hex.length == 6 ? 0xFF000000 | parsed : parsed);
}

@immutable
class DrawingShape {
  const DrawingShape({
    required this.id,
    required this.kind,
    required this.points,
    required this.color,
    this.strokeWidth = 2.0,
    this.text,
  });

  factory DrawingShape.fromJson(Map<String, dynamic> json) => DrawingShape(
        id: json['id'] as String,
        kind: shapeKindFromWire(json['kind'] as String?),
        points: [
          for (final point in (json['points'] as List?) ?? [])
            NormalizedPoint.fromJson(point as Map<String, dynamic>),
        ],
        // Un color ilegible cae al cian de acento en vez de romper el render: el trazo se ve, aunque
        // con otro tono, y el usuario puede corregirlo.
        color: hexToColor(json['color'] as String?) ?? const Color(0xFF22D3EE),
        strokeWidth: (json['stroke_width'] as num?)?.toDouble() ?? 2.0,
        text: json['text'] as String?,
      );

  final String id;
  final ShapeKind kind;
  final List<NormalizedPoint> points;
  final Color color;
  final double strokeWidth;

  /// Solo para [ShapeKind.text].
  final String? text;

  /// ¿La forma se puede dibujar y guardar?
  ///
  /// Es la misma regla que valida el backend. Se chequea acá para no mandar una forma que va a
  /// volver como 422 y, sobre todo, para no intentar pintar una recta sin segundo punto — que sería
  /// una excepción en medio del `paint`, es decir un frame rojo.
  bool get isDrawable {
    final required = kind.requiredPoints;
    if (required != null && points.length != required) return false;
    if (kind == ShapeKind.freehand && points.length < 2) return false;
    if (kind == ShapeKind.text) return (text ?? '').trim().isNotEmpty;
    return true;
  }

  DrawingShape copyWith({
    List<NormalizedPoint>? points,
    Color? color,
    double? strokeWidth,
    String? text,
  }) =>
      DrawingShape(
        id: id,
        kind: kind,
        points: points ?? this.points,
        color: color ?? this.color,
        strokeWidth: strokeWidth ?? this.strokeWidth,
        text: text ?? this.text,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.wireValue,
        'points': [for (final point in points) point.toJson()],
        'color': colorToHex(color),
        'stroke_width': strokeWidth,
        // El backend RECHAZA `text` en una forma que no es TEXT, así que solo se emite donde
        // corresponde: mandarlo siempre sería un 422 en cada línea que se dibuje.
        if (kind == ShapeKind.text) 'text': text,
      };

  @override
  bool operator ==(Object other) =>
      other is DrawingShape &&
      other.id == id &&
      other.kind == kind &&
      listEquals(other.points, points) &&
      other.color == color &&
      other.strokeWidth == strokeWidth &&
      other.text == text;

  @override
  int get hashCode =>
      Object.hash(id, kind, Object.hashAll(points), color, strokeWidth, text);
}

@immutable
class DrawingLayer {
  const DrawingLayer({this.version = 1, this.shapes = const []});

  factory DrawingLayer.fromJson(Map<String, dynamic> json) => DrawingLayer(
        version: json['version'] as int? ?? 1,
        shapes: [
          for (final shape in (json['shapes'] as List?) ?? [])
            DrawingShape.fromJson(shape as Map<String, dynamic>),
        ],
      );

  static const empty = DrawingLayer();

  final int version;
  final List<DrawingShape> shapes;

  bool get isEmpty => shapes.isEmpty;
  bool get isNotEmpty => shapes.isNotEmpty;

  /// Solo las formas que se pueden pintar.
  ///
  /// Una capa guardada por una versión anterior puede traer una forma que este cliente no sabe
  /// dibujar; se salta esa y se pintan las demás, en vez de dejar la captura sin anotaciones.
  List<DrawingShape> get drawable =>
      shapes.where((shape) => shape.isDrawable).toList();

  DrawingLayer copyWith({List<DrawingShape>? shapes}) =>
      DrawingLayer(version: version, shapes: shapes ?? this.shapes);

  Map<String, dynamic> toJson() => {
        'version': version,
        'shapes': [for (final shape in shapes) shape.toJson()],
      };

  @override
  bool operator ==(Object other) =>
      other is DrawingLayer &&
      other.version == version &&
      listEquals(other.shapes, shapes);

  @override
  int get hashCode => Object.hash(version, Object.hashAll(shapes));
}

@immutable
class NoteAttachment {
  const NoteAttachment({
    required this.id,
    required this.noteId,
    required this.ticker,
    required this.contentType,
    required this.byteSize,
    required this.width,
    required this.height,
    required this.caption,
    required this.source,
    required this.drawing,
    required this.imageUrl,
    required this.createdAt,
    required this.updatedAt,
  });

  factory NoteAttachment.fromJson(Map<String, dynamic> json) => NoteAttachment(
        id: json['id'] as String,
        noteId: json['note_id'] as String,
        ticker: json['ticker'] as String?,
        contentType: json['content_type'] as String? ?? 'image/png',
        byteSize: json['byte_size'] as int? ?? 0,
        width: json['width'] as int?,
        height: json['height'] as int?,
        caption: json['caption'] as String?,
        source: json['source'] as String?,
        drawing: DrawingLayer.fromJson(
          (json['drawing'] as Map<String, dynamic>?) ?? const {},
        ),
        imageUrl: json['image_url'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );

  final String id;
  final String noteId;
  final String? ticker;
  final String contentType;
  final int byteSize;
  final int? width;
  final int? height;
  final String? caption;
  final String? source;
  final DrawingLayer drawing;

  /// Ruta relativa de los bytes, tal como la arma el backend. NO se concatena del lado del cliente:
  /// si la ruta cambia, esta app sigue funcionando.
  final String imageUrl;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// Relación ancho/alto de la imagen, si el backend la conoce.
  ///
  /// `null` cuando el cliente que subió la captura no declaró las dimensiones. En ese caso el visor
  /// tiene que sacarla de la imagen ya decodificada — dibujar las anotaciones antes de saberla las
  /// pondría en el lugar equivocado.
  double? get aspectRatio {
    final w = width;
    final h = height;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return w / h;
  }

  bool get hasAnnotations => drawing.isNotEmpty;

  int get shapeCount => drawing.shapes.length;

  NoteAttachment copyWith({DrawingLayer? drawing, String? caption}) =>
      NoteAttachment(
        id: id,
        noteId: noteId,
        ticker: ticker,
        contentType: contentType,
        byteSize: byteSize,
        width: width,
        height: height,
        caption: caption ?? this.caption,
        source: source,
        drawing: drawing ?? this.drawing,
        imageUrl: imageUrl,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}

/// Lo que se manda al subir una captura.
@immutable
class AttachmentDraft {
  const AttachmentDraft({
    required this.imageBytes,
    this.contentType = 'image/png',
    this.ticker,
    this.caption,
    this.source,
    this.width,
    this.height,
    this.drawing = DrawingLayer.empty,
  });

  final Uint8List imageBytes;
  final String contentType;
  final String? ticker;
  final String? caption;
  final String? source;
  final int? width;
  final int? height;
  final DrawingLayer drawing;
}
