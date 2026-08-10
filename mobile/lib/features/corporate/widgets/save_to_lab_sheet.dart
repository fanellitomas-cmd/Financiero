import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../lab/data/note.dart';
import '../../lab/data/note_formatting.dart';
import '../../lab/presentation/lab_controller.dart';
import '../../lab/widgets/markdown_view.dart';
import '../data/corporate_note_snippet.dart';

/// "Guardar en el Lab": manda un balance, un reporte o una noticia a una nota, nueva o existente.
///
/// Una sola hoja para los cuatro tipos de bloque y no un botón distinto por pestaña: lo que cambia
/// entre ellos es el Markdown que ya viene armado, y la decisión que el usuario tiene que tomar
/// —¿nota nueva o agregar a una que ya tengo?— es siempre la misma.
///
/// Se PREGUNTA a dónde va antes de escribir, y no se crea una carpeta "Corporativo" por defecto:
/// acumular recortes en un lugar que el usuario no eligió convierte el Lab en un cajón, que es
/// exactamente lo que ese módulo existe para evitar.
///
/// Al agregar a una nota existente el cuerpo se **anexa al final**: el contenido actual puede ser la
/// tesis escrita a mano, y reemplazarla por datos que se pueden volver a pedir sería la peor pérdida
/// posible acá.
class SaveToLabSheet extends ConsumerStatefulWidget {
  const SaveToLabSheet({
    super.key,
    required this.heading,
    required this.draft,
    required this.snippet,
    this.ticker,
  });

  /// Qué se está guardando, en una línea ("Balance de NVDA del 27/08/2026").
  final String heading;

  /// La nota nueva, con título y cuerpo ya compuestos.
  final NoteDraft draft;

  /// El mismo cuerpo, suelto, para poder anexarlo a una nota que ya existe.
  final String snippet;

  /// Si viene, la lista de candidatas son las notas de ese símbolo. Sin ticker (una noticia de
  /// mercado) se ofrecen las últimas notas del Lab: son las que el usuario está escribiendo ahora.
  final String? ticker;

  static Future<void> show(
    BuildContext context, {
    required String heading,
    required NoteDraft draft,
    required String snippet,
    String? ticker,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SaveToLabSheet(
        heading: heading,
        draft: draft,
        snippet: snippet,
        ticker: ticker,
      ),
    );
  }

  @override
  ConsumerState<SaveToLabSheet> createState() => _SaveToLabSheetState();
}

class _SaveToLabSheetState extends ConsumerState<SaveToLabSheet> {
  late final TextEditingController _titleController =
      TextEditingController(text: widget.draft.title);

  bool _busy = false;
  String? _error;
  bool _previewOpen = false;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String successMessage) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await action();
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(successMessage)));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeApiError(error);
      });
    }
  }

  Future<void> _saveAsNewNote() => _run(
        () => ref.read(labActionsProvider).createNote(
              widget.draft.copyWith(title: _titleController.text),
            ),
        'Se creó la nota en el Investment Lab.',
      );

  Future<void> _appendToNote(NoteSummary summary) => _run(
        () async {
          // Se pide la nota COMPLETA antes de guardar: el listado trae solo el resumen, y guardar
          // con el cuerpo del resumen borraría todo lo que la nota tenía escrito.
          final note = await ref.read(notesRepositoryProvider).get(summary.id);
          await ref.read(labActionsProvider).saveNote(
                note.id,
                NoteDraft.fromNote(note).copyWith(
                  content: appendCorporateSnippet(note.content, widget.snippet),
                ),
              );
        },
        'Se agregó al final de "${summary.title}".',
      );

  /// Las notas candidatas. Con ticker, las de ese símbolo; sin ticker, las últimas del Lab.
  List<NoteSummary> _candidates() {
    final ticker = widget.ticker;
    final page = ticker == null
        ? ref.watch(notesProvider(const LabFilter())).valueOrNull
        : ref.watch(tickerNotesProvider(ticker)).valueOrNull;
    return page?.items ?? const <NoteSummary>[];
  }

  @override
  Widget build(BuildContext context) {
    final notes = _candidates();

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
                const Icon(Icons.science_outlined,
                    size: 18, color: AppTheme.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Guardar en el Lab',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.heading,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _titleController,
              maxLength: 180,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Título de la nota nueva',
              ),
            ),
            // La vista previa es plegable y arranca cerrada: lo que se guarda son datos que el
            // usuario acaba de ver en pantalla, así que abrirla siempre robaría el alto que necesita
            // la lista de notas. Pero está, porque lo que queda escrito en una nota es definitivo.
            _PreviewToggle(
              open: _previewOpen,
              onToggle: () => setState(() => _previewOpen = !_previewOpen),
            ),
            if (_previewOpen)
              Container(
                constraints: const BoxConstraints(maxHeight: 220),
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceSunken,
                  borderRadius: BorderRadius.circular(AppTheme.radius),
                  border: Border.all(color: AppTheme.border),
                ),
                child: SingleChildScrollView(
                  child: MarkdownView(source: widget.snippet, textScale: 0.9),
                ),
              ),
            if (_error != null) ...[
              Text(
                _error!,
                style: const TextStyle(color: AppTheme.bearish, fontSize: 12),
              ),
              const SizedBox(height: 10),
            ],
            FilledButton.icon(
              onPressed: _busy ? null : _saveAsNewNote,
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
                      'o agregarlo al final de una nota',
                      style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
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
                        color: note.pinned
                            ? AppTheme.accent
                            : AppTheme.textMuted,
                      ),
                      title: Text(
                        note.title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        '${formatRelativeTime(note.updatedAt)} · '
                        '${formatContentLength(note.contentLength)}'
                        '${note.ticker == null ? "" : " · ${note.ticker}"}',
                        style: AppTheme.numeric(
                            fontSize: 10, color: AppTheme.textMuted),
                      ),
                      onTap: _busy ? null : () => _appendToNote(note),
                    );
                  },
                ),
              ),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  widget.ticker == null
                      ? 'Todavía no tenés notas en el Lab. Esta va a ser la primera.'
                      : 'Todavía no tenés notas sobre ${widget.ticker}. '
                          'Esta va a estrenar una.',
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textMuted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PreviewToggle extends StatelessWidget {
  const _PreviewToggle({required this.open, required this.onToggle});

  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: onToggle,
        icon: Icon(open ? Icons.expand_less : Icons.expand_more, size: 16),
        label: Text(
          open ? 'Ocultar lo que se va a guardar' : 'Ver lo que se va a guardar',
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }
}

/// Botón estándar de "guardar esto en el Lab", para las filas de las cuatro pestañas.
///
/// Existe para que el gesto sea idéntico en todas: un ícono distinto por pestaña obligaría a
/// aprender cuatro veces la misma acción.
class SaveToLabButton extends StatelessWidget {
  const SaveToLabButton({
    super.key,
    required this.heading,
    required this.draft,
    required this.snippet,
    this.ticker,
    this.tooltip,
  });

  final String heading;
  final NoteDraft draft;
  final String snippet;
  final String? ticker;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
      tooltip: tooltip ?? 'Guardar en el Investment Lab',
      onPressed: () => SaveToLabSheet.show(
        context,
        heading: heading,
        draft: draft,
        snippet: snippet,
        ticker: ticker,
      ),
    );
  }
}
