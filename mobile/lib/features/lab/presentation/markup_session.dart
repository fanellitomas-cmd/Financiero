import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;

import '../data/note_attachment.dart';

/// El estado editable de una capa de anotaciones: las formas, el trazo en curso y el historial.
///
/// Vive fuera del widget a propósito. El editor es la pieza con más lógica del módulo —construcción
/// de formas por herramienta, deshacer/rehacer, detección de cambios sin guardar— y toda esa lógica
/// es verificable sin montar un canvas ni simular gestos si no depende de un `BuildContext`.
///
/// El historial guarda **listas completas** y no operaciones inversas. Es más memoria (una lista de
/// punteros por paso, no una imagen), pero deshacer nunca puede quedar desincronizado: cada paso ES
/// el estado, no una receta para reconstruirlo.
class MarkupSession extends ChangeNotifier {
  MarkupSession({
    required DrawingLayer initial,
    String Function()? idGenerator,
  })  : _initialShapes = List.unmodifiable(initial.shapes),
        _version = initial.version,
        _shapes = List.of(initial.shapes),
        _nextId = idGenerator ?? _defaultIdGenerator;

  /// Tope del historial. Cien pasos cubren cualquier sesión de anotación real y acotan la memoria:
  /// sin tope, un trazo libre largo apilaría un estado por cada gesto durante toda la sesión.
  static const int maxHistory = 100;

  static String _defaultIdGenerator() =>
      's${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  final List<DrawingShape> _initialShapes;
  final int _version;
  final String Function() _nextId;

  List<DrawingShape> _shapes;
  final List<List<DrawingShape>> _past = [];
  final List<List<DrawingShape>> _future = [];

  /// El trazo que se está dibujando ahora mismo. Se pinta encima de [shapes] pero NO forma parte de
  /// ellas hasta soltar el dedo: si formara parte, cada frame del arrastre sería un paso de
  /// deshacer.
  DrawingShape? _draft;

  List<DrawingShape> get shapes => List.unmodifiable(_shapes);
  DrawingShape? get draft => _draft;

  /// Lo que hay que pintar: lo confirmado más el trazo en curso.
  List<DrawingShape> get visibleShapes => [
        ..._shapes,
        if (_draft != null) _draft!,
      ];

  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;
  bool get isEmpty => _shapes.isEmpty;

  /// ¿Hay algo que guardar?
  ///
  /// Se compara contra la capa que llegó del servidor y no con un flag que se prende al primer
  /// trazo: dibujar una línea y deshacerla vuelve a dejar el editor limpio, en vez de quedar marcado
  /// como sucio para siempre.
  bool get isDirty => !listEquals(_shapes, _initialShapes);

  DrawingLayer toLayer() =>
      DrawingLayer(version: _version, shapes: List.of(_shapes));

  // --- Trazo en curso -------------------------------------------------------------------------

  /// Arranca una forma. Para las herramientas de dos puntos, el segundo arranca igual al primero y
  /// se va moviendo con el dedo.
  void beginStroke({
    required ShapeKind kind,
    required NormalizedPoint at,
    required Color color,
    required double strokeWidth,
  }) {
    if (kind == ShapeKind.text) return;

    _draft = DrawingShape(
      id: _nextId(),
      kind: kind,
      points: kind == ShapeKind.freehand ? [at] : [at, at],
      color: color,
      strokeWidth: strokeWidth,
    );
    notifyListeners();
  }

  void extendStroke(NormalizedPoint at) {
    final draft = _draft;
    if (draft == null) return;

    if (draft.kind == ShapeKind.freehand) {
      // Se descartan los puntos casi pegados: un arrastre lento genera cientos de muestras a menos
      // de un píxel entre sí, que no cambian el trazo y sí hacen crecer el JSON hasta el tope de
      // 2000 puntos del backend.
      final last = draft.points.last;
      final moved = (at.x - last.x).abs() + (at.y - last.y).abs();
      if (moved < _freehandEpsilon) return;
      _draft = draft.copyWith(points: [...draft.points, at]);
    } else {
      _draft = draft.copyWith(points: [draft.points.first, at]);
    }
    notifyListeners();
  }

  /// Distancia mínima (en unidades normalizadas) entre dos muestras de un trazo libre. 0.002 sobre
  /// una captura de 1200px es poco más de 2px: por debajo de eso el punto no aporta forma.
  static const double _freehandEpsilon = 0.002;

  /// Confirma el trazo en curso. Uno degenerado —un toque que no llegó a moverse— se descarta: una
  /// línea de largo cero es invisible y ocuparía un paso de deshacer.
  void commitStroke() {
    final draft = _draft;
    _draft = null;
    if (draft == null) {
      notifyListeners();
      return;
    }

    if (!draft.isDrawable || _isDegenerate(draft)) {
      notifyListeners();
      return;
    }

    _pushHistory();
    _shapes = [..._shapes, draft];
    notifyListeners();
  }

  void cancelStroke() {
    if (_draft == null) return;
    _draft = null;
    notifyListeners();
  }

  static bool _isDegenerate(DrawingShape shape) {
    if (shape.kind == ShapeKind.text) return false;
    final first = shape.points.first;
    final last = shape.points.last;
    return (first.x - last.x).abs() < _freehandEpsilon &&
        (first.y - last.y).abs() < _freehandEpsilon;
  }

  // --- Texto ----------------------------------------------------------------------------------

  /// Agrega una anotación de texto. Se ignora la vacía: el backend la rechaza con 422 y, sobre todo,
  /// no dibuja nada — dejarla apilaría un paso de deshacer sin efecto visible.
  void addText({
    required NormalizedPoint at,
    required String text,
    required Color color,
    required double strokeWidth,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    _pushHistory();
    _shapes = [
      ..._shapes,
      DrawingShape(
        id: _nextId(),
        kind: ShapeKind.text,
        points: [at],
        color: color,
        strokeWidth: strokeWidth,
        text: trimmed,
      ),
    ];
    notifyListeners();
  }

  // --- Historial ------------------------------------------------------------------------------

  void undo() {
    if (_past.isEmpty) return;
    _future.add(_shapes);
    _shapes = _past.removeLast();
    _draft = null;
    notifyListeners();
  }

  void redo() {
    if (_future.isEmpty) return;
    _past.add(_shapes);
    _shapes = _future.removeLast();
    _draft = null;
    notifyListeners();
  }

  /// Borra todas las formas. Es un paso más del historial, no una operación destructiva: "limpiar"
  /// sin poder deshacer sería un botón que puede tirar veinte minutos de anotación de un toque.
  void clear() {
    if (_shapes.isEmpty && _draft == null) return;
    _pushHistory();
    _shapes = const [];
    _draft = null;
    notifyListeners();
  }

  void _pushHistory() {
    _past.add(_shapes);
    if (_past.length > maxHistory) _past.removeAt(0);
    // Cualquier acción nueva corta la rama de rehacer: mantenerla dejaría un "rehacer" que
    // reaparecería un estado incompatible con lo que se acaba de dibujar.
    _future.clear();
  }
}
