import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../data/drawing_geometry.dart';
import '../data/note_attachment.dart';
import '../presentation/attachments_controller.dart';
import '../presentation/markup_session.dart';
import 'drawing_painter.dart';

/// Paleta del editor de anotaciones.
///
/// Los cuatro colores del tema y nada más. Un selector libre daría un gris sobre un chart oscuro o
/// un verde que se confunde con una vela alcista; acá cada color YA significa algo en la app, así
/// que una marca roja sobre un soporte se lee igual que el resto del producto.
const List<({Color color, String label})> kMarkupPalette = [
  (color: AppTheme.bullish, label: 'Alcista'),
  (color: AppTheme.bearish, label: 'Bajista'),
  (color: AppTheme.accent, label: 'Neutral'),
  (color: AppTheme.neutral, label: 'Atención'),
];

const List<double> kStrokeWidths = [1.5, 3.0, 5.0];

/// Editor visual de anotaciones sobre una captura de gráfico.
///
/// Se abre como pantalla completa y no como diálogo: dibujar sobre un chart necesita todo el ancho
/// disponible, y una precisión de un par de píxeles que un modal de 500px no da.
class ChartMarkupEditor extends ConsumerStatefulWidget {
  const ChartMarkupEditor({super.key, required this.attachment});

  final NoteAttachment attachment;

  /// Abre el editor y devuelve `true` si se guardó algo.
  static Future<bool> open(
    BuildContext context,
    NoteAttachment attachment,
  ) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ChartMarkupEditor(attachment: attachment),
      ),
    );
    return saved ?? false;
  }

  @override
  ConsumerState<ChartMarkupEditor> createState() => _ChartMarkupEditorState();
}

class _ChartMarkupEditorState extends ConsumerState<ChartMarkupEditor> {
  late final MarkupSession _session =
      MarkupSession(initial: widget.attachment.drawing);

  ShapeKind _tool = ShapeKind.freehand;
  Color _color = AppTheme.accent;
  double _strokeWidth = 3.0;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    _session.dispose();
    super.dispose();
  }

  void _onSessionChanged() => setState(() {});

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await ref.read(attachmentActionsProvider).saveDrawing(
            widget.attachment.noteId,
            widget.attachment.id,
            _session.toLayer(),
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = describeApiError(error);
      });
    }
  }

  Future<void> _confirmClose() async {
    if (!_session.isDirty) {
      Navigator.of(context).pop(false);
      return;
    }

    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Anotaciones sin guardar'),
        content: const Text(
          'Los trazos que hiciste todavía no se guardaron. Si salís, se pierden.',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Seguir editando'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.bearish),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Descartar'),
          ),
        ],
      ),
    );

    if ((discard ?? false) && mounted) Navigator.of(context).pop(false);
  }

  Future<void> _promptText(NormalizedPoint at) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => const _TextAnnotationDialog(),
    );

    if (text == null) return;
    _session.addText(
      at: at,
      text: text,
      color: _color,
      strokeWidth: _strokeWidth,
    );
  }

  @override
  Widget build(BuildContext context) {
    final imageAsync = ref.watch(attachmentImageProvider(widget.attachment.imageUrl));

    return PopScope(
      // `canPop: false` + confirmación: el gesto de "atrás" del sistema tiene que preguntar igual
      // que el botón de cerrar, si no el trabajo se pierde por deslizar sin querer.
      canPop: !_session.isDirty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _confirmClose();
      },
      child: Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Cerrar el editor',
            onPressed: _confirmClose,
          ),
          title: Text(
            widget.attachment.ticker == null
                ? 'Anotar la captura'
                : 'Anotar ${widget.attachment.ticker}',
          ),
          actions: [
            if (_session.isDirty)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Center(child: _DirtyPill()),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                onPressed: _session.isDirty && !_saving ? _save : null,
                icon: _saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined, size: 16),
                label: const Text('Guardar'),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_error != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                color: AppTheme.bearish.withValues(alpha: 0.12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppTheme.bearish, fontSize: 12),
                ),
              ),
            Expanded(
              child: imageAsync.when(
                data: (bytes) => _MarkupCanvas(
                  imageBytes: bytes,
                  aspectRatio: widget.attachment.aspectRatio,
                  session: _session,
                  tool: _tool,
                  color: _color,
                  strokeWidth: _strokeWidth,
                  referenceWidth: widget.attachment.width?.toDouble(),
                  onRequestText: _promptText,
                ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, stackTrace) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.image_not_supported_outlined,
                            size: 36, color: AppTheme.textMuted),
                        const SizedBox(height: 12),
                        Text(describeApiError(error),
                            textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () => ref.invalidate(
                            attachmentImageProvider(widget.attachment.imageUrl),
                          ),
                          child: const Text('Reintentar'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            _MarkupToolbar(
              tool: _tool,
              color: _color,
              strokeWidth: _strokeWidth,
              canUndo: _session.canUndo,
              canRedo: _session.canRedo,
              canClear: !_session.isEmpty,
              onToolChanged: (tool) => setState(() => _tool = tool),
              onColorChanged: (color) => setState(() => _color = color),
              onStrokeChanged: (width) => setState(() => _strokeWidth = width),
              onUndo: _session.undo,
              onRedo: _session.redo,
              onClear: _session.clear,
            ),
          ],
        ),
      ),
    );
  }
}

/// La imagen con el canvas de dibujo encima.
class _MarkupCanvas extends StatelessWidget {
  const _MarkupCanvas({
    required this.imageBytes,
    required this.aspectRatio,
    required this.session,
    required this.tool,
    required this.color,
    required this.strokeWidth,
    required this.referenceWidth,
    required this.onRequestText,
  });

  final Uint8List imageBytes;
  final double? aspectRatio;
  final MarkupSession session;
  final ShapeKind tool;
  final Color color;
  final double strokeWidth;
  final double? referenceWidth;
  final ValueChanged<NormalizedPoint> onRequestText;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          // La MISMA geometría que usa el painter. Que el gesto y el trazo compartan el cálculo es
          // lo que hace que la línea salga exactamente de donde se apoyó el dedo.
          final geometry = DrawingGeometry.contain(size, aspectRatio);

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: tool == ShapeKind.text
                ? (details) => onRequestText(
                      geometry.toNormalized(details.localPosition),
                    )
                : null,
            onPanStart: tool == ShapeKind.text
                ? null
                : (details) => session.beginStroke(
                      kind: tool,
                      at: geometry.toNormalized(details.localPosition),
                      color: color,
                      strokeWidth: strokeWidth,
                    ),
            onPanUpdate: tool == ShapeKind.text
                ? null
                : (details) => session.extendStroke(
                      geometry.toNormalized(details.localPosition),
                    ),
            onPanEnd: tool == ShapeKind.text
                ? null
                : (_) => session.commitStroke(),
            // Un gesto cancelado (otro puntero, o el sistema robando el foco) descarta el trazo en
            // vez de dejarlo a medias donde quedó el dedo.
            onPanCancel: tool == ShapeKind.text ? null : session.cancelStroke,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(
                  imageBytes,
                  fit: BoxFit.contain,
                  // `filterQuality` alto: una captura de chart escalada con el filtro por defecto
                  // deja las velas finas con bordes sucios.
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                ),
                CustomPaint(
                  painter: DrawingPainter(
                    shapes: session.visibleShapes,
                    aspectRatio: aspectRatio,
                    referenceWidth: referenceWidth,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Pide el texto de una anotación.
///
/// Widget propio en vez de un `showDialog` con un controller de la pantalla: el `TextEditingController`
/// tiene que vivir y morir con el diálogo. Descartándolo apenas `showDialog` resuelve, el campo lo
/// sigue usando durante la animación de salida y Flutter lanza "used after being disposed".
class _TextAnnotationDialog extends StatefulWidget {
  const _TextAnnotationDialog();

  @override
  State<_TextAnnotationDialog> createState() => _TextAnnotationDialogState();
}

class _TextAnnotationDialogState extends State<_TextAnnotationDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Anotación de texto'),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 280,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.of(context).pop(value),
          decoration: const InputDecoration(
            labelText: 'Texto',
            hintText: 'Resistencia, soporte, objetivo…',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Agregar'),
        ),
      ],
    );
  }
}

class _DirtyPill extends StatelessWidget {
  const _DirtyPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: AppTheme.badgeDecoration(AppTheme.neutral),
      child: Text(
        'SIN GUARDAR',
        style: AppTheme.numeric(fontSize: 9, color: AppTheme.neutral)
            .copyWith(fontWeight: FontWeight.bold, letterSpacing: 0.6),
      ),
    );
  }
}

class _MarkupToolbar extends StatelessWidget {
  const _MarkupToolbar({
    required this.tool,
    required this.color,
    required this.strokeWidth,
    required this.canUndo,
    required this.canRedo,
    required this.canClear,
    required this.onToolChanged,
    required this.onColorChanged,
    required this.onStrokeChanged,
    required this.onUndo,
    required this.onRedo,
    required this.onClear,
  });

  final ShapeKind tool;
  final Color color;
  final double strokeWidth;
  final bool canUndo;
  final bool canRedo;
  final bool canClear;
  final ValueChanged<ShapeKind> onToolChanged;
  final ValueChanged<Color> onColorChanged;
  final ValueChanged<double> onStrokeChanged;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onClear;

  static const Map<ShapeKind, IconData> _icons = {
    ShapeKind.freehand: Icons.gesture,
    ShapeKind.line: Icons.horizontal_rule,
    ShapeKind.arrow: Icons.north_east,
    ShapeKind.rect: Icons.crop_square,
    ShapeKind.ellipse: Icons.circle_outlined,
    ShapeKind.text: Icons.title,
  };

  @override
  Widget build(BuildContext context) {
    return Material(
      // `Material` y no `Container(color:)`: un `ColoredBox` entre el Scaffold y los botones taparía
      // los ink splashes, que es justamente la única realimentación de que el toque se registró.
      color: AppTheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Wrap(
            spacing: 14,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // Herramientas
              Wrap(
                spacing: 2,
                children: [
                  for (final kind in ShapeKind.values)
                    IconButton(
                      iconSize: 20,
                      visualDensity: VisualDensity.compact,
                      tooltip: kind.displayName,
                      isSelected: kind == tool,
                      onPressed: () => onToolChanged(kind),
                      icon: Icon(
                        _icons[kind],
                        color: kind == tool ? AppTheme.accent : AppTheme.textMuted,
                      ),
                    ),
                ],
              ),
              const _ToolbarDivider(),
              // Colores
              Wrap(
                spacing: 6,
                children: [
                  for (final swatch in kMarkupPalette)
                    _ColorDot(
                      color: swatch.color,
                      label: swatch.label,
                      selected: swatch.color == color,
                      onTap: () => onColorChanged(swatch.color),
                    ),
                ],
              ),
              const _ToolbarDivider(),
              // Grosor
              Wrap(
                spacing: 2,
                children: [
                  for (final width in kStrokeWidths)
                    _StrokeDot(
                      width: width,
                      selected: width == strokeWidth,
                      onTap: () => onStrokeChanged(width),
                    ),
                ],
              ),
              const _ToolbarDivider(),
              // Historial
              Wrap(
                spacing: 2,
                children: [
                  IconButton(
                    iconSize: 20,
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Deshacer',
                    onPressed: canUndo ? onUndo : null,
                    icon: const Icon(Icons.undo),
                  ),
                  IconButton(
                    iconSize: 20,
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Rehacer',
                    onPressed: canRedo ? onRedo : null,
                    icon: const Icon(Icons.redo),
                  ),
                  IconButton(
                    iconSize: 20,
                    visualDensity: VisualDensity.compact,
                    // Limpiar es un paso más del historial, así que se puede deshacer: por eso no
                    // pide confirmación.
                    tooltip: 'Limpiar todo (se puede deshacer)',
                    onPressed: canClear ? onClear : null,
                    icon: const Icon(Icons.layers_clear_outlined),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolbarDivider extends StatelessWidget {
  const _ToolbarDivider();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 22, child: VerticalDivider(width: 1, color: AppTheme.border));
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              // El anillo blanco es lo único que distingue el color activo. Sin él, cuatro puntos de
              // colores no dicen cuál está seleccionado.
              border: Border.all(
                color: selected ? Colors.white : Colors.transparent,
                width: 2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StrokeDot extends StatelessWidget {
  const _StrokeDot({
    required this.width,
    required this.selected,
    required this.onTap,
  });

  final double width;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Grosor ${width.toStringAsFixed(1)}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 30,
          height: 26,
          alignment: Alignment.center,
          child: Container(
            width: 18,
            height: width,
            decoration: BoxDecoration(
              color: selected ? AppTheme.accent : AppTheme.textMuted,
              borderRadius: BorderRadius.circular(width),
            ),
          ),
        ),
      ),
    );
  }
}
