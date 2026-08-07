import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../data/chart_snapshot.dart';
import '../data/note.dart';
import '../data/note_formatting.dart';
import '../data/note_attachment.dart';
import '../presentation/attachments_controller.dart';
import '../presentation/lab_controller.dart';
import 'chart_markup_editor.dart';

/// "Exportar Gráfico al Lab": elige a qué nota va la captura y la sube.
///
/// Se pregunta a dónde va ANTES de subir, y no se crea una nota "Capturas de NVDA" por defecto:
/// acumular capturas sueltas en una nota que el usuario no eligió convierte el Lab en un cajón, que
/// es exactamente lo que el módulo existe para evitar.
class ExportChartSheet extends ConsumerStatefulWidget {
  const ExportChartSheet({
    super.key,
    required this.snapshot,
    required this.ticker,
  });

  final ChartSnapshot snapshot;
  final String ticker;

  static Future<void> show(
    BuildContext context, {
    required ChartSnapshot snapshot,
    required String ticker,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => ExportChartSheet(snapshot: snapshot, ticker: ticker),
    );
  }

  @override
  ConsumerState<ExportChartSheet> createState() => _ExportChartSheetState();
}

class _ExportChartSheetState extends ConsumerState<ExportChartSheet> {
  // Fecha absoluta y no relativa: el epígrafe queda escrito para siempre dentro de la nota, y
  // "hace 2 h" leído en tres meses no dice nada.
  late final TextEditingController _captionController = TextEditingController(
    text: 'Gráfico de ${widget.ticker} · '
        '${DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now())}',
  );

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  AttachmentDraft get _draft => AttachmentDraft(
        imageBytes: widget.snapshot.bytes,
        ticker: widget.ticker,
        caption: _captionController.text.trim().isEmpty
            ? null
            : _captionController.text.trim(),
        source: 'chart',
        width: widget.snapshot.width,
        height: widget.snapshot.height,
      );

  Future<void> _run(Future<NoteAttachment> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final attachment = await action();
      if (!mounted) return;
      Navigator.of(context).pop();

      // Se abre el editor apenas se sube: la razón de exportar un gráfico es marcarlo, y obligar a
      // buscar la nota en el Lab para dar el primer trazo rompe el hilo de lo que se estaba
      // mirando.
      await ChartMarkupEditor.open(context, attachment);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeApiError(error);
      });
    }
  }

  Future<void> _exportToNewNote() => _run(() async {
        final note = await ref.read(labActionsProvider).createNote(
              NoteDraft.blank(
                ticker: widget.ticker,
                title: _captionController.text.trim().isEmpty
                    ? 'Gráfico de ${widget.ticker}'
                    : _captionController.text.trim(),
              ),
            );
        return ref
            .read(attachmentActionsProvider)
            .upload(note.id, _draft);
      });

  Future<void> _exportToExistingNote(NoteSummary note) =>
      _run(() => ref.read(attachmentActionsProvider).upload(note.id, _draft));

  @override
  Widget build(BuildContext context) {
    // Las notas del ticker: son las candidatas obvias para una captura de SU gráfico. Ofrecer todas
    // las notas del Lab haría scrollear entre tesis de otros activos para encontrar la correcta.
    final notesAsync = ref.watch(tickerNotesProvider(widget.ticker));
    final notes = notesAsync.valueOrNull?.items ?? const <NoteSummary>[];

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.candlestick_chart_outlined,
                    size: 18, color: AppTheme.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Exportar el gráfico de ${widget.ticker} al Lab',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  '${widget.snapshot.width}×${widget.snapshot.height}',
                  style: AppTheme.numeric(
                      fontSize: 10, color: AppTheme.textMuted),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _SnapshotPreview(snapshot: widget.snapshot),
            const SizedBox(height: 14),
            TextField(
              controller: _captionController,
              maxLength: 300,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Título / epígrafe',
                helperText: 'Se usa como título si creás una nota nueva.',
              ),
            ),
            const SizedBox(height: 6),
            if (_error != null) ...[
              Text(
                _error!,
                style: const TextStyle(color: AppTheme.bearish, fontSize: 12),
              ),
              const SizedBox(height: 10),
            ],
            FilledButton.icon(
              onPressed: _busy ? null : _exportToNewNote,
              icon: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.note_add_outlined, size: 16),
              label: const Text('Crear una nota nueva'),
            ),
            const SizedBox(height: 14),
            if (notes.isNotEmpty) ...[
              const Row(
                children: [
                  Expanded(child: Divider(color: AppTheme.border)),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      'o agregarlo a una nota existente',
                      style:
                          TextStyle(fontSize: 11, color: AppTheme.textMuted),
                    ),
                  ),
                  Expanded(child: Divider(color: AppTheme.border)),
                ],
              ),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: notes.length,
                  itemBuilder: (context, index) {
                    final note = notes[index];
                    return ListTile(
                      dense: true,
                      enabled: !_busy,
                      leading: Icon(
                        note.pinned
                            ? Icons.push_pin
                            : Icons.sticky_note_2_outlined,
                        size: 17,
                        color: AppTheme.textMuted,
                      ),
                      title: Text(
                        note.title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        formatRelativeTime(note.updatedAt),
                        style: AppTheme.numeric(
                            fontSize: 10, color: AppTheme.textMuted),
                      ),
                      onTap: _busy ? null : () => _exportToExistingNote(note),
                    );
                  },
                ),
              ),
            ] else
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Todavía no tenés notas sobre este activo. La captura va a estrenar una.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SnapshotPreview extends StatelessWidget {
  const _SnapshotPreview({required this.snapshot});

  final ChartSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radius),
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border.all(color: AppTheme.border)),
        // Se muestra lo que se va a subir, no una descripción de ello: si la captura salió recortada
        // o en blanco, se ve acá y no dentro de una nota una semana después.
        child: AspectRatio(
          aspectRatio: snapshot.aspectRatio,
          child: Image.memory(
            snapshot.bytes,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ),
    );
  }
}
