import 'dart:convert';
import 'dart:typed_data';

import 'package:financiero_app/core/providers.dart';
import 'package:financiero_app/core/theme/app_theme.dart';
import 'package:financiero_app/features/lab/data/attachments_repository.dart';
import 'package:financiero_app/features/lab/data/drawing_geometry.dart';
import 'package:financiero_app/features/lab/data/note_attachment.dart';
import 'package:financiero_app/features/lab/presentation/markup_session.dart';
import 'package:financiero_app/features/lab/widgets/attachment_card.dart';
import 'package:financiero_app/features/lab/widgets/chart_markup_editor.dart';
import 'package:financiero_app/features/lab/widgets/drawing_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests del módulo de análisis gráfico: modelos, geometría, sesión de edición y UI.
///
/// Los contratos que este módulo promete y que son fáciles de romper sin darse cuenta:
///
///   1. **Las coordenadas son normalizadas y se mapean al rectángulo REAL de la imagen.** Con
///      `BoxFit.contain` una captura apaisada deja bandas; mapear 0..1 sobre el widget entero pondría
///      una flecha que marca un máximo de precio en medio de la banda negra. Y el desfasaje solo se
///      notaría al cambiar el tamaño de la ventana.
///   2. **El gesto y el trazo usan la MISMA geometría.** Si divergieran, la línea no saldría de donde
///      se apoyó el dedo.
///   3. **Deshacer compara contra lo guardado.** Dibujar y deshacer vuelve a dejar el editor limpio,
///      en vez de marcado como sucio para siempre.
///   4. **El PUT manda solo el dibujo.** La imagen no se retransmite: guardar una flecha sobre una
///      captura de 800 KB tiene que costar unos cientos de bytes.

// --- Fixtures ----------------------------------------------------------------------------------

/// PNG real de 1×1, para que `Image.memory` pueda decodificarlo en los tests de widget.
final Uint8List kPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9'
  'awAAAABJRU5ErkJggg==',
);

NoteAttachment _attachment({
  String id = 'a1',
  String noteId = 'n1',
  DrawingLayer drawing = DrawingLayer.empty,
  int? width = 1200,
  int? height = 600,
  String? caption = 'Ruptura de la resistencia',
  String? ticker = 'NVDA',
}) =>
    NoteAttachment(
      id: id,
      noteId: noteId,
      ticker: ticker,
      contentType: 'image/png',
      byteSize: 4200,
      width: width,
      height: height,
      caption: caption,
      source: 'chart',
      drawing: drawing,
      imageUrl: '/api/v1/notes/$noteId/attachments/$id/image',
      createdAt: DateTime.utc(2026, 8, 6, 10),
      updatedAt: DateTime.utc(2026, 8, 6, 10),
    );

DrawingShape _line({
  String id = 's1',
  Color color = AppTheme.accent,
  double strokeWidth = 2,
  List<(double, double)> points = const [(0.1, 0.2), (0.8, 0.6)],
}) =>
    DrawingShape(
      id: id,
      kind: ShapeKind.line,
      points: [for (final (x, y) in points) NormalizedPoint(x, y)],
      color: color,
      strokeWidth: strokeWidth,
    );

class _FakeAttachmentsRepository implements AttachmentsRepository {
  _FakeAttachmentsRepository({List<NoteAttachment> attachments = const []})
      : _attachments = List.of(attachments);

  List<NoteAttachment> _attachments;
  Object? failure;

  final List<(String, AttachmentDraft)> uploaded = [];
  final List<(String, String, DrawingLayer)> saved = [];
  final List<String> removed = [];
  int imageLoads = 0;

  @override
  Future<List<NoteAttachment>> list(String noteId) async => _attachments;

  @override
  Future<NoteAttachment> create(String noteId, AttachmentDraft draft) async {
    if (failure != null) throw failure!;
    uploaded.add((noteId, draft));
    final created = _attachment(id: 'nueva', noteId: noteId);
    _attachments = [..._attachments, created];
    return created;
  }

  @override
  Future<NoteAttachment> updateDrawing(
    String noteId,
    String attachmentId,
    DrawingLayer drawing, {
    String? caption,
    String? ticker,
    bool clearTicker = false,
  }) async {
    if (failure != null) throw failure!;
    saved.add((noteId, attachmentId, drawing));
    return _attachment(id: attachmentId, noteId: noteId, drawing: drawing);
  }

  @override
  Future<void> remove(String noteId, String attachmentId) async {
    removed.add(attachmentId);
  }

  @override
  Future<Uint8List> loadImage(String imageUrl) async {
    imageLoads++;
    return kPngBytes;
  }
}

Future<void> _pumpEditor(
  WidgetTester tester,
  _FakeAttachmentsRepository repository, {
  NoteAttachment? attachment,
  Size size = const Size(900, 1200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        attachmentsRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        theme: AppTheme.dark,
        home: ChartMarkupEditor(attachment: attachment ?? _attachment()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // --- Modelos ----------------------------------------------------------------------------------

  group('NormalizedPoint', () {
    test('recorta al rango 0..1 en vez de dejar pasar un valor inválido', () {
      // Un dedo que se va del borde produciría un 1.03 que el backend rechaza con 422 — y el usuario
      // perdería el trazo entero por haberse pasado dos píxeles.
      expect(NormalizedPoint(1.4, -0.3).x, 1.0);
      expect(NormalizedPoint(1.4, -0.3).y, 0.0);
      expect(NormalizedPoint(0.42, 0.7).x, 0.42);
    });

    test('un valor no finito cae a 0 en vez de propagar un NaN', () {
      expect(NormalizedPoint(double.nan, double.infinity).x, 0.0);
      expect(NormalizedPoint(double.nan, double.infinity).y, 0.0);
    });
  });

  group('colores', () {
    test('el hexadecimal conserva el canal alfa', () {
      // Un resaltado semitransparente y un trazo sólido son dos herramientas distintas: perder el
      // alfa al guardar convertiría una en la otra.
      expect(colorToHex(const Color(0x4422D3EE)), '#4422d3ee');
      expect(colorToHex(AppTheme.bullish), '#ff10b981');
    });

    test('acepta las dos formas y trata `#rrggbb` como opaco', () {
      expect(hexToColor('#22d3ee'), const Color(0xFF22D3EE));
      expect(hexToColor('#4422d3ee'), const Color(0x4422D3EE));
      expect(hexToColor('rojo'), isNull);
      expect(hexToColor('#12345'), isNull);
      expect(hexToColor(null), isNull);
    });

    test('un color ilegible degrada al acento en vez de romper el render', () {
      final shape = DrawingShape.fromJson(const {
        'id': 's',
        'kind': 'LINE',
        'points': [
          {'x': 0.1, 'y': 0.1},
          {'x': 0.5, 'y': 0.5},
        ],
        'color': 'no-es-color',
      });

      expect(shape.color, AppTheme.accent);
    });
  });

  group('DrawingShape', () {
    test('el JSON solo lleva `text` en las formas TEXT', () {
      // El backend RECHAZA `text` en una forma que no es TEXT: mandarlo siempre sería un 422 en cada
      // línea que se dibuje.
      expect(_line().toJson().containsKey('text'), isFalse);

      final text = DrawingShape(
        id: 't',
        kind: ShapeKind.text,
        points: [NormalizedPoint(0.5, 0.5)],
        color: AppTheme.neutral,
        text: 'Resistencia',
      );
      expect(text.toJson()['text'], 'Resistencia');
    });

    test('isDrawable aplica la misma aridad que valida el backend', () {
      expect(_line().isDrawable, isTrue);
      expect(_line(points: const [(0.1, 0.1)]).isDrawable, isFalse);
      expect(
        _line(points: const [(0.1, 0.1), (0.5, 0.5), (0.9, 0.9)]).isDrawable,
        isFalse,
      );

      DrawingShape freehand(int count) => DrawingShape(
            id: 'f',
            kind: ShapeKind.freehand,
            points: [
              for (var i = 0; i < count; i++) NormalizedPoint(i / 10, i / 10),
            ],
            color: AppTheme.accent,
          );
      expect(freehand(1).isDrawable, isFalse);
      expect(freehand(2).isDrawable, isTrue);

      DrawingShape text(String? value) => DrawingShape(
            id: 't',
            kind: ShapeKind.text,
            points: [NormalizedPoint(0.5, 0.5)],
            color: AppTheme.accent,
            text: value,
          );
      expect(text(null).isDrawable, isFalse);
      expect(text('   ').isDrawable, isFalse);
      expect(text('Soporte').isDrawable, isTrue);
    });

    test('una herramienta desconocida degrada a línea, no rompe la capa', () {
      final layer = DrawingLayer.fromJson(const {
        'version': 1,
        'shapes': [
          {
            'id': 'x',
            'kind': 'HOLOGRAMA',
            'points': [
              {'x': 0.1, 'y': 0.1},
              {'x': 0.5, 'y': 0.5},
            ],
            'color': '#ffffff',
          },
        ],
      });

      expect(layer.shapes.single.kind, ShapeKind.line);
      expect(layer.drawable, hasLength(1));
    });

    test('`drawable` deja afuera lo que no se puede pintar', () {
      final layer = DrawingLayer(shapes: [
        _line(),
        _line(id: 'rota', points: const [(0.1, 0.1)]),
      ]);

      expect(layer.shapes, hasLength(2));
      // La forma rota se saltea y las demás se dibujan igual: una capa vieja no puede dejar la
      // captura sin ninguna anotación.
      expect(layer.drawable.map((shape) => shape.id), ['s1']);
    });

    test('el ida y vuelta por JSON conserva la forma', () {
      final original = _line(color: const Color(0x8010B981), strokeWidth: 4.5);
      expect(DrawingShape.fromJson(original.toJson()), original);
    });
  });

  group('NoteAttachment', () {
    test('la proporción sale de las dimensiones declaradas', () {
      expect(_attachment(width: 1200, height: 600).aspectRatio, 2.0);
    });

    test('sin dimensiones no se inventa una proporción', () {
      // Dibujar antes de saberla pondría las anotaciones en el lugar equivocado; `null` deja que el
      // visor asuma que la imagen llena el widget, que es lo único que no desplaza nada.
      expect(_attachment(width: null, height: 600).aspectRatio, isNull);
      expect(_attachment(width: 1200, height: 0).aspectRatio, isNull);
    });
  });

  // --- Geometría --------------------------------------------------------------------------------

  group('DrawingGeometry', () {
    test('descuenta las bandas del contain en un widget más ancho', () {
      // Imagen 2:1 en un widget cuadrado de 400: la imagen mide 400x200 y queda centrada.
      const geometry = DrawingGeometry.contain;
      final fitted = geometry(const Size(400, 400), 2.0);

      expect(fitted.imageRect, const Rect.fromLTWH(0, 100, 400, 200));
    });

    test('descuenta las bandas laterales en un widget más alto', () {
      final fitted = DrawingGeometry.contain(const Size(400, 100), 2.0);

      expect(fitted.imageRect, const Rect.fromLTWH(100, 0, 200, 100));
    });

    test('sin proporción conocida la imagen llena el widget', () {
      final fitted = DrawingGeometry.contain(const Size(400, 300), null);

      expect(fitted.imageRect, const Rect.fromLTWH(0, 0, 400, 300));
    });

    test('el mapeo usa el rectángulo de la imagen, no el del widget', () {
      // ES el bug que este test existe para evitar: con el widget entero, el centro de la imagen
      // caería en y=200 en vez de y=200... y una marca al 100% de la altura caería en la banda.
      final fitted = DrawingGeometry.contain(const Size(400, 400), 2.0);

      expect(fitted.toPixels(NormalizedPoint(0, 0)), const Offset(0, 100));
      expect(fitted.toPixels(NormalizedPoint(1, 1)), const Offset(400, 300));
      expect(fitted.toPixels(NormalizedPoint(0.5, 0.5)), const Offset(200, 200));
    });

    test('la vuelta a normalizado es la inversa exacta del mapeo', () {
      // Es lo que garantiza que la línea salga de donde se apoyó el dedo: el gesto y el painter usan
      // esta misma geometría.
      final fitted = DrawingGeometry.contain(const Size(640, 480), 16 / 9);
      final original = NormalizedPoint(0.37, 0.62);

      final round = fitted.toNormalized(fitted.toPixels(original));

      expect(round.x, closeTo(original.x, 1e-9));
      expect(round.y, closeTo(original.y, 1e-9));
    });

    test('un gesto fuera de la imagen se recorta al borde', () {
      final fitted = DrawingGeometry.contain(const Size(400, 400), 2.0);

      // y=20 cae en la banda superior: se convierte en el borde de la imagen, no en un negativo.
      expect(fitted.toNormalized(const Offset(200, 20)).y, 0.0);
      expect(fitted.toNormalized(const Offset(900, 200)).x, 1.0);
    });

    test('el grosor escala con el tamaño mostrado', () {
      // Una línea de 3px trazada sobre una captura de 1200px no puede verse igual de gruesa en una
      // miniatura de 300px: taparía el gráfico.
      final full = DrawingGeometry.contain(const Size(1200, 600), 2.0);
      final thumb = DrawingGeometry.contain(const Size(300, 150), 2.0);

      expect(full.strokeScale(1200), 1.0);
      expect(thumb.strokeScale(1200), closeTo(0.25, 1e-9));
    });

    test('el factor tiene piso para que un trazo no desaparezca', () {
      final tiny = DrawingGeometry.contain(const Size(30, 15), 2.0);

      // Una anotación invisible es indistinguible de una que no se guardó.
      expect(tiny.strokeScale(1200), 0.25);
    });

    test('sin ancho de referencia no se escala', () {
      final fitted = DrawingGeometry.contain(const Size(300, 150), 2.0);
      expect(fitted.strokeScale(null), 1.0);
    });

    test('un tamaño degenerado no lanza', () {
      expect(
        DrawingGeometry.contain(Size.zero, 2.0).imageRect,
        Rect.zero,
      );
      expect(
        DrawingGeometry.contain(const Size(100, 100), 0).imageRect,
        const Rect.fromLTWH(0, 0, 100, 100),
      );
    });
  });

  // --- Sesión de edición ------------------------------------------------------------------------

  group('MarkupSession', () {
    MarkupSession session({DrawingLayer? initial}) {
      var counter = 0;
      return MarkupSession(
        initial: initial ?? DrawingLayer.empty,
        idGenerator: () => 'id${counter++}',
      );
    }

    test('un trazo se confirma al soltar, no mientras se arrastra', () {
      final markup = session();

      markup.beginStroke(
        kind: ShapeKind.line,
        at: NormalizedPoint(0.1, 0.1),
        color: AppTheme.accent,
        strokeWidth: 2,
      );
      markup.extendStroke(NormalizedPoint(0.6, 0.6));

      // Todavía no está confirmado: si lo estuviera, cada frame del arrastre sería un paso de
      // deshacer.
      expect(markup.shapes, isEmpty);
      expect(markup.draft, isNotNull);
      expect(markup.visibleShapes, hasLength(1));

      markup.commitStroke();
      expect(markup.shapes, hasLength(1));
      expect(markup.draft, isNull);
      expect(markup.shapes.single.points.last, NormalizedPoint(0.6, 0.6));
    });

    test('un toque que no se movió se descarta', () {
      // Una línea de largo cero es invisible y ocuparía un paso de deshacer.
      final markup = session();

      markup.beginStroke(
        kind: ShapeKind.line,
        at: NormalizedPoint(0.3, 0.3),
        color: AppTheme.accent,
        strokeWidth: 2,
      );
      markup.commitStroke();

      expect(markup.shapes, isEmpty);
      expect(markup.canUndo, isFalse);
    });

    test('el trazo libre acumula puntos y descarta los casi pegados', () {
      final markup = session();

      markup.beginStroke(
        kind: ShapeKind.freehand,
        at: NormalizedPoint(0.1, 0.1),
        color: AppTheme.accent,
        strokeWidth: 2,
      );
      markup.extendStroke(NormalizedPoint(0.1001, 0.1001)); // muy cerca
      markup.extendStroke(NormalizedPoint(0.3, 0.3));
      markup.extendStroke(NormalizedPoint(0.5, 0.5));
      markup.commitStroke();

      // Un arrastre lento genera cientos de muestras a menos de un píxel que no cambian el trazo y
      // sí hacen crecer el JSON hasta el tope del backend.
      expect(markup.shapes.single.points, hasLength(3));
    });

    test('cancelar descarta el trazo en curso', () {
      final markup = session();

      markup.beginStroke(
        kind: ShapeKind.rect,
        at: NormalizedPoint(0.1, 0.1),
        color: AppTheme.accent,
        strokeWidth: 2,
      );
      markup.extendStroke(NormalizedPoint(0.5, 0.5));
      markup.cancelStroke();

      expect(markup.draft, isNull);
      expect(markup.shapes, isEmpty);
    });

    test('la herramienta de texto no arranca un trazo', () {
      // El texto se agrega con un toque y un diálogo, no arrastrando.
      final markup = session();

      markup.beginStroke(
        kind: ShapeKind.text,
        at: NormalizedPoint(0.1, 0.1),
        color: AppTheme.accent,
        strokeWidth: 2,
      );

      expect(markup.draft, isNull);
    });

    test('un texto vacío no se agrega', () {
      final markup = session();

      markup.addText(
        at: NormalizedPoint(0.5, 0.5),
        text: '   ',
        color: AppTheme.accent,
        strokeWidth: 2,
      );

      expect(markup.shapes, isEmpty);
      expect(markup.canUndo, isFalse);
    });

    test('el texto se guarda recortado', () {
      final markup = session();

      markup.addText(
        at: NormalizedPoint(0.5, 0.5),
        text: '  Resistencia  ',
        color: AppTheme.neutral,
        strokeWidth: 2,
      );

      expect(markup.shapes.single.text, 'Resistencia');
      expect(markup.shapes.single.kind, ShapeKind.text);
    });

    test('deshacer y rehacer recorren el historial', () {
      final markup = session();

      void draw(double x) {
        markup.beginStroke(
          kind: ShapeKind.line,
          at: NormalizedPoint(x, 0.1),
          color: AppTheme.accent,
          strokeWidth: 2,
        );
        markup.extendStroke(NormalizedPoint(x + 0.2, 0.5));
        markup.commitStroke();
      }

      draw(0.1);
      draw(0.4);
      expect(markup.shapes, hasLength(2));

      markup.undo();
      expect(markup.shapes, hasLength(1));
      expect(markup.canRedo, isTrue);

      markup.undo();
      expect(markup.shapes, isEmpty);
      expect(markup.canUndo, isFalse);

      markup.redo();
      markup.redo();
      expect(markup.shapes, hasLength(2));
      expect(markup.canRedo, isFalse);
    });

    test('dibujar corta la rama de rehacer', () {
      final markup = session();

      markup.addText(
        at: NormalizedPoint(0.1, 0.1),
        text: 'uno',
        color: AppTheme.accent,
        strokeWidth: 2,
      );
      markup.undo();
      expect(markup.canRedo, isTrue);

      markup.addText(
        at: NormalizedPoint(0.5, 0.5),
        text: 'dos',
        color: AppTheme.accent,
        strokeWidth: 2,
      );

      // Mantenerla dejaría un "rehacer" que reaparecería un estado incompatible con lo recién
      // dibujado.
      expect(markup.canRedo, isFalse);
      expect(markup.shapes.single.text, 'dos');
    });

    test('limpiar se puede deshacer', () {
      // Si no, sería un botón que tira veinte minutos de anotación de un toque.
      final markup = session(initial: DrawingLayer(shapes: [_line(), _line(id: 's2')]));

      markup.clear();
      expect(markup.isEmpty, isTrue);

      markup.undo();
      expect(markup.shapes, hasLength(2));
    });

    test('limpiar una capa vacía no apila un paso', () {
      final markup = session();
      markup.clear();
      expect(markup.canUndo, isFalse);
    });

    test('isDirty compara contra lo guardado, no contra el primer trazo', () {
      final markup = session(initial: DrawingLayer(shapes: [_line()]));
      expect(markup.isDirty, isFalse);

      markup.addText(
        at: NormalizedPoint(0.5, 0.5),
        text: 'nota',
        color: AppTheme.accent,
        strokeWidth: 2,
      );
      expect(markup.isDirty, isTrue);

      // Dibujar y deshacer vuelve a dejar el editor limpio, en vez de marcado como sucio para
      // siempre.
      markup.undo();
      expect(markup.isDirty, isFalse);
    });

    test('notifica a sus oyentes en cada cambio', () {
      final markup = session();
      var notifications = 0;
      markup.addListener(() => notifications++);

      markup.addText(
        at: NormalizedPoint(0.5, 0.5),
        text: 'x',
        color: AppTheme.accent,
        strokeWidth: 2,
      );
      markup.undo();

      expect(notifications, 2);
    });

    test('toLayer conserva la versión del formato', () {
      final markup = session(initial: const DrawingLayer(version: 3));
      expect(markup.toLayer().version, 3);
    });
  });

  // --- Painter ----------------------------------------------------------------------------------

  group('DrawingPainter', () {
    test('repinta cuando cambian las formas y no cuando son iguales', () {
      const base = DrawingPainter(shapes: [], aspectRatio: 2);
      final withShape = DrawingPainter(shapes: [_line()], aspectRatio: 2);

      expect(withShape.shouldRepaint(base), isTrue);
      // Listas distintas con el mismo contenido: el editor reconstruye la lista en cada trazo, y
      // comparar referencias repintaría siempre.
      expect(
        DrawingPainter(shapes: [_line()], aspectRatio: 2)
            .shouldRepaint(withShape),
        isFalse,
      );
      expect(
        DrawingPainter(shapes: [_line()], aspectRatio: 3)
            .shouldRepaint(withShape),
        isTrue,
      );
    });

    testWidgets('dibuja las seis herramientas sin lanzar', (tester) async {
      // El painter corre en cada frame: una excepción acá es un frame rojo, no un error de red que
      // se pueda reintentar.
      final shapes = [
        _line(),
        DrawingShape(
          id: 'a',
          kind: ShapeKind.arrow,
          points: [NormalizedPoint(0.2, 0.8), NormalizedPoint(0.7, 0.2)],
          color: AppTheme.bullish,
        ),
        DrawingShape(
          id: 'r',
          kind: ShapeKind.rect,
          points: [NormalizedPoint(0.1, 0.1), NormalizedPoint(0.4, 0.4)],
          color: AppTheme.bearish,
        ),
        DrawingShape(
          id: 'e',
          kind: ShapeKind.ellipse,
          points: [NormalizedPoint(0.5, 0.5), NormalizedPoint(0.8, 0.9)],
          color: AppTheme.neutral,
        ),
        DrawingShape(
          id: 'f',
          kind: ShapeKind.freehand,
          points: [
            NormalizedPoint(0.1, 0.2),
            NormalizedPoint(0.3, 0.4),
            NormalizedPoint(0.6, 0.3),
          ],
          color: AppTheme.accent,
        ),
        DrawingShape(
          id: 't',
          kind: ShapeKind.text,
          points: [NormalizedPoint(0.5, 0.05)],
          color: AppTheme.accent,
          text: 'Máximo histórico',
        ),
        // Una forma imposible mezclada: se saltea sin romper el frame.
        _line(id: 'rota', points: const [(0.1, 0.1)]),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 300,
              child: CustomPaint(
                painter: DrawingPainter(shapes: shapes, aspectRatio: 2),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('una flecha de largo cero no lanza al calcular su punta',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomPaint(
              painter: DrawingPainter(
                shapes: [
                  DrawingShape(
                    id: 'a',
                    kind: ShapeKind.arrow,
                    points: [
                      NormalizedPoint(0.5, 0.5),
                      NormalizedPoint(0.5, 0.5),
                    ],
                    color: AppTheme.accent,
                  ),
                ],
                aspectRatio: 1,
              ),
              size: const Size(200, 200),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });

  // --- Editor -----------------------------------------------------------------------------------

  group('ChartMarkupEditor', () {
    testWidgets('arranca con la barra completa y sin cambios que guardar',
        (tester) async {
      await _pumpEditor(tester, _FakeAttachmentsRepository());

      for (final kind in ShapeKind.values) {
        expect(find.byTooltip(kind.displayName), findsOneWidget);
      }
      for (final swatch in kMarkupPalette) {
        expect(find.byTooltip(swatch.label), findsOneWidget);
      }
      expect(find.byTooltip('Deshacer'), findsOneWidget);
      expect(find.byTooltip('Rehacer'), findsOneWidget);
      expect(find.textContaining('Limpiar todo'), findsNothing);

      expect(find.text('SIN GUARDAR'), findsNothing);
      final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Guardar'),
      );
      expect(save.onPressed, isNull);
    });

    testWidgets('dibujar marca sin guardar y el PUT manda solo el dibujo',
        (tester) async {
      final repository = _FakeAttachmentsRepository();
      await _pumpEditor(tester, repository);

      // Arrastre sobre el canvas: la herramienta por defecto es el trazo libre.
      final canvas = find.byType(CustomPaint).first;
      await tester.drag(canvas, const Offset(120, 90));
      await tester.pumpAndSettle();

      expect(find.text('SIN GUARDAR'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
      await tester.pumpAndSettle();

      expect(repository.saved, hasLength(1));
      final (noteId, attachmentId, layer) = repository.saved.single;
      expect(noteId, 'n1');
      expect(attachmentId, 'a1');
      expect(layer.shapes, hasLength(1));
      expect(layer.shapes.single.kind, ShapeKind.freehand);
      // La imagen NO se retransmite: guardar una flecha sobre una captura de 800 KB cuesta unos
      // cientos de bytes.
      expect(repository.uploaded, isEmpty);
    });

    testWidgets('el trazo usa el color y el grosor elegidos', (tester) async {
      final repository = _FakeAttachmentsRepository();
      await _pumpEditor(tester, repository);

      await tester.tap(find.byTooltip('Bajista'));
      await tester.tap(find.byTooltip('Grosor 5.0'));
      await tester.tap(find.byTooltip('Línea'));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(CustomPaint).first, const Offset(150, 80));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
      await tester.pumpAndSettle();

      final shape = repository.saved.single.$3.shapes.single;
      expect(shape.kind, ShapeKind.line);
      expect(shape.color, AppTheme.bearish);
      expect(shape.strokeWidth, 5.0);
    });

    testWidgets('deshacer vuelve a dejar el editor sin cambios', (tester) async {
      await _pumpEditor(tester, _FakeAttachmentsRepository());

      await tester.drag(find.byType(CustomPaint).first, const Offset(100, 60));
      await tester.pumpAndSettle();
      expect(find.text('SIN GUARDAR'), findsOneWidget);

      await tester.tap(find.byTooltip('Deshacer'));
      await tester.pumpAndSettle();

      expect(find.text('SIN GUARDAR'), findsNothing);
      final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Guardar'),
      );
      expect(save.onPressed, isNull);
    });

    testWidgets('la herramienta de texto pide el contenido antes de agregarlo',
        (tester) async {
      final repository = _FakeAttachmentsRepository();
      await _pumpEditor(tester, repository);

      await tester.tap(find.byTooltip('Texto'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(400, 400));
      await tester.pumpAndSettle();

      expect(find.text('Anotación de texto'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Texto'),
        'Resistencia 640',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Agregar'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
      await tester.pumpAndSettle();

      final shape = repository.saved.single.$3.shapes.single;
      expect(shape.kind, ShapeKind.text);
      expect(shape.text, 'Resistencia 640');
    });

    testWidgets('salir con trazos sin guardar pide confirmación',
        (tester) async {
      await _pumpEditor(tester, _FakeAttachmentsRepository());

      await tester.drag(find.byType(CustomPaint).first, const Offset(100, 60));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Cerrar el editor'));
      await tester.pumpAndSettle();

      expect(find.text('Anotaciones sin guardar'), findsOneWidget);
      await tester.tap(find.text('Seguir editando'));
      await tester.pumpAndSettle();
      // Sigue en el editor con el trazo intacto.
      expect(find.text('SIN GUARDAR'), findsOneWidget);
    });

    testWidgets('un error al guardar se muestra y no cierra el editor',
        (tester) async {
      final repository = _FakeAttachmentsRepository()
        ..failure = Exception('sin red');
      await _pumpEditor(tester, repository);

      await tester.drag(find.byType(CustomPaint).first, const Offset(100, 60));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Ocurrió un error'), findsOneWidget);
      expect(find.text('SIN GUARDAR'), findsOneWidget);
    });

    testWidgets('las anotaciones ya guardadas se cargan al abrir',
        (tester) async {
      await _pumpEditor(
        tester,
        _FakeAttachmentsRepository(),
        attachment: _attachment(
          drawing: DrawingLayer(shapes: [_line(), _line(id: 's2')]),
        ),
      );

      // Abre limpio pero con las formas ya puestas: se puede deshacer nada y sí limpiar.
      expect(find.text('SIN GUARDAR'), findsNothing);
      final clear = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('Limpiar todo (se puede deshacer)'),
          matching: find.byType(IconButton),
        ),
      );
      expect(clear.onPressed, isNotNull);
    });
  });

  // --- Tarjeta incrustada en la nota --------------------------------------------------------------

  group('NoteAttachmentsSection', () {
    Future<void> pumpSection(
      WidgetTester tester,
      _FakeAttachmentsRepository repository,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            attachmentsRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const Scaffold(
              body: SingleChildScrollView(
                child: NoteAttachmentsSection(noteId: 'n1'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('sin capturas no dibuja ni un encabezado', (tester) async {
      // La mayoría de las notas son solo texto: una sección "Gráficos (0)" en todas sería ruido
      // permanente.
      await pumpSection(tester, _FakeAttachmentsRepository());

      expect(find.textContaining('Análisis Técnico'), findsNothing);
    });

    testWidgets('muestra el indicador de Análisis Técnico y los metadatos',
        (tester) async {
      await pumpSection(
        tester,
        _FakeAttachmentsRepository(attachments: [
          _attachment(drawing: DrawingLayer(shapes: [_line(), _line(id: 's2')])),
          _attachment(id: 'a2', caption: 'Segunda', drawing: DrawingLayer.empty),
        ]),
      );

      expect(find.text('Análisis Técnico · 2 gráficos'), findsOneWidget);
      expect(find.text('Ruptura de la resistencia'), findsOneWidget);
      // Cuántos trazos tiene cada una, para distinguir de un vistazo la trabajada de la pendiente.
      expect(find.textContaining('2 trazos'), findsOneWidget);
      expect(find.textContaining('sin anotar'), findsOneWidget);
      expect(find.text('NVDA'), findsNWidgets(2));
    });

    testWidgets('la pista de edición dice si ya tiene trazos', (tester) async {
      await pumpSection(
        tester,
        _FakeAttachmentsRepository(attachments: [
          _attachment(drawing: DrawingLayer(shapes: [_line()])),
          _attachment(id: 'a2', caption: 'Sin marcar'),
        ]),
      );

      // Sin la pista, una imagen dentro de una nota no se lee como un botón.
      expect(find.text('Editar trazos'), findsOneWidget);
      expect(find.text('Anotar'), findsOneWidget);
    });

    testWidgets('tocar una captura abre el editor de anotaciones',
        (tester) async {
      await pumpSection(
        tester,
        _FakeAttachmentsRepository(attachments: [_attachment()]),
      );

      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      expect(find.byType(ChartMarkupEditor), findsOneWidget);
      expect(find.text('Anotar NVDA'), findsOneWidget);
    });

    testWidgets('la imagen se baja una sola vez para miniatura y editor',
        (tester) async {
      // El mismo megabyte se muestra en los dos lugares; bajarlo dos veces sería pedirlo dos veces
      // en la misma pantalla.
      final repository =
          _FakeAttachmentsRepository(attachments: [_attachment()]);
      await pumpSection(tester, repository);
      expect(repository.imageLoads, 1);

      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      expect(repository.imageLoads, 1);
    });
  });
}
