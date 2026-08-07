import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../../lab/data/note.dart';
import '../../lab/data/note_formatting.dart';
import '../../lab/presentation/lab_controller.dart';
import '../../lab/widgets/attachment_card.dart';
import '../../lab/widgets/markdown_view.dart';
import '../data/intelligence_note_snippet.dart';
import '../presentation/deep_intelligence_controller.dart';

/// Pestaña "Notas" de la ficha de un activo: las notas del Lab vinculadas a ese símbolo.
///
/// Filtra por `ticker` y NO por carpeta, que es justamente el punto de que los dos ejes sean
/// independientes en el backend: una nota de NVDA archivada en "Semiconductores" y otra suelta en la
/// raíz aparecen las dos acá. Si la vinculación al activo dependiera de la carpeta, organizar el Lab
/// rompería esta pestaña.
///
/// Se lee y se escribe en el mismo lugar: la nota se expande en línea con su cuerpo renderizado, y se
/// edita en un campo ahí mismo. Mandar al usuario al Lab para agregar dos líneas sobre el activo que
/// está mirando rompería el hilo de lo que estaba haciendo.
class TickerNotesTab extends ConsumerWidget {
  const TickerNotesTab({super.key, required this.ticker});

  final String ticker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notesAsync = ref.watch(tickerNotesProvider(ticker));

    return Column(
      children: [
        _TickerNotesToolbar(ticker: ticker),
        const Divider(height: 1, color: AppTheme.border),
        Expanded(
          child: notesAsync.when(
            data: (page) => page.items.isEmpty
                ? _EmptyTickerNotes(ticker: ticker)
                : RefreshIndicator(
                    onRefresh: () async =>
                        ref.invalidate(tickerNotesProvider(ticker)),
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: page.items.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1, color: AppTheme.border),
                      itemBuilder: (context, index) => _TickerNoteTile(
                        summary: page.items[index],
                        ticker: ticker,
                      ),
                    ),
                  ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stackTrace) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(describeApiError(error), textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () =>
                          ref.invalidate(tickerNotesProvider(ticker)),
                      child: const Text('Reintentar'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TickerNotesToolbar extends ConsumerWidget {
  const _TickerNotesToolbar({required this.ticker});

  final String ticker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final total = ref.watch(tickerNotesProvider(ticker)).valueOrNull?.total;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          const Icon(Icons.science_outlined, size: 16, color: AppTheme.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              total == null
                  ? 'Notas sobre $ticker'
                  : 'Notas sobre $ticker · $total',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.open_in_new, size: 18),
            tooltip: 'Abrir el Investment Lab',
            onPressed: () => context.push('/lab'),
          ),
          _InsertIntelligenceButton(ticker: ticker),
          IconButton(
            icon: const Icon(Icons.note_add_outlined, size: 20),
            tooltip: 'Nueva nota sobre $ticker',
            onPressed: () => NoteComposerDialog.show(context, ref, ticker: ticker),
          ),
        ],
      ),
    );
  }
}

/// "Insertar la Ficha en una nota".
///
/// Solo aparece habilitado cuando la Ficha de Inteligencia ya está cargada en memoria: el botón
/// escribe lo que la pestaña de al lado está mostrando, y dispararlo para pedirla convertiría un
/// gesto de un clic en una espera de varios segundos con un resultado que el usuario no vio.
class _InsertIntelligenceButton extends ConsumerWidget {
  const _InsertIntelligenceButton({required this.ticker});

  final String ticker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final intelligence = ref.watch(deepIntelligenceProvider(ticker)).valueOrNull;

    return IconButton(
      icon: const Icon(Icons.auto_awesome_outlined, size: 19),
      tooltip: intelligence == null
          ? 'Abrí la pestaña de Inteligencia Profunda para poder insertarla en una nota'
          : 'Nueva nota con la Ficha de Inteligencia de $ticker',
      onPressed: intelligence == null
          ? null
          : () => NoteComposerDialog.show(
                context,
                ref,
                ticker: ticker,
                initialDraft: intelligenceNoteDraft(intelligence),
              ),
    );
  }
}

/// Una nota del activo, colapsada. Al expandirla se pide el cuerpo completo y se renderiza.
class _TickerNoteTile extends ConsumerStatefulWidget {
  const _TickerNoteTile({required this.summary, required this.ticker});

  final NoteSummary summary;
  final String ticker;

  @override
  ConsumerState<_TickerNoteTile> createState() => _TickerNoteTileState();
}

class _TickerNoteTileState extends ConsumerState<_TickerNoteTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          dense: true,
          onTap: () => setState(() => _expanded = !_expanded),
          leading: Icon(
            summary.pinned ? Icons.push_pin : Icons.sticky_note_2_outlined,
            size: 17,
            color: summary.pinned ? AppTheme.accent : AppTheme.textMuted,
          ),
          title: Text(
            summary.title,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${formatRelativeTime(summary.updatedAt)} · '
            '${formatContentLength(summary.contentLength)}',
            style: AppTheme.numeric(fontSize: 10, color: AppTheme.textMuted),
          ),
          trailing: Icon(
            _expanded ? Icons.expand_less : Icons.expand_more,
            size: 20,
          ),
        ),
        // El cuerpo se pide RECIÉN al expandir: el listado solo trae resúmenes, y traer veinte
        // cuerpos completos por si acaso es exactamente lo que el contrato evita.
        if (_expanded) _ExpandedNoteBody(noteId: summary.id, ticker: widget.ticker),
      ],
    );
  }
}

class _ExpandedNoteBody extends ConsumerWidget {
  const _ExpandedNoteBody({required this.noteId, required this.ticker});

  final String noteId;
  final String ticker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final noteAsync = ref.watch(noteDetailProvider(noteId));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      color: AppTheme.surfaceSunken,
      child: noteAsync.when(
        data: (note) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MarkdownView(source: note.content, textScale: 0.95),
            const SizedBox(height: 12),
            // Los gráficos de la nota se ven acá mismo: una tesis técnica sin la captura que la
            // motivó pierde la mitad del argumento.
            NoteAttachmentsSection(noteId: note.id),
            const SizedBox(height: 10),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () => NoteComposerDialog.show(
                    context,
                    ref,
                    ticker: ticker,
                    existingNote: note,
                  ),
                  icon: const Icon(Icons.edit_outlined, size: 15),
                  label: const Text('Editar'),
                ),
                const SizedBox(width: 8),
                _AppendIntelligenceAction(note: note, ticker: ticker),
              ],
            ),
          ],
        ),
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
        error: (error, stackTrace) => Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            describeApiError(error),
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
          ),
        ),
      ),
    );
  }
}

/// Agrega la Ficha al final de una nota que ya existe.
class _AppendIntelligenceAction extends ConsumerWidget {
  const _AppendIntelligenceAction({required this.note, required this.ticker});

  final Note note;
  final String ticker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final intelligence = ref.watch(deepIntelligenceProvider(ticker)).valueOrNull;

    return OutlinedButton.icon(
      onPressed: intelligence == null
          ? null
          : () async {
              try {
                await ref.read(labActionsProvider).saveNote(
                      note.id,
                      NoteDraft.fromNote(note).copyWith(
                        // Se AGREGA al final: el cuerpo actual puede ser la tesis escrita a mano, y
                        // reemplazarla por datos que se pueden regenerar sería la peor pérdida
                        // posible acá.
                        content:
                            appendIntelligenceSnippet(note.content, intelligence),
                      ),
                    );
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Se agregó la Ficha al final de la nota.'),
                  ),
                );
              } on Object catch (error) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(describeApiError(error))),
                );
              }
            },
      icon: const Icon(Icons.auto_awesome_outlined, size: 15),
      label: const Text('Agregar la Ficha'),
    );
  }
}

/// Redactor rápido de una nota, desde la ficha del activo.
///
/// Es un diálogo y no el editor completo del Lab a propósito: acá el usuario está mirando un activo y
/// quiere anotar algo sin cambiar de contexto. Para reorganizar carpetas o escribir largo está el
/// Lab, al que se llega con el botón de la barra.
class NoteComposerDialog extends ConsumerStatefulWidget {
  const NoteComposerDialog({
    super.key,
    required this.ticker,
    this.existingNote,
    this.initialDraft,
  });

  final String ticker;

  /// Si viene, se edita esa nota en vez de crear una nueva.
  final Note? existingNote;

  /// Contenido inicial de una nota nueva (por ejemplo la Ficha ya pegada).
  final NoteDraft? initialDraft;

  static Future<void> show(
    BuildContext context,
    WidgetRef ref, {
    required String ticker,
    Note? existingNote,
    NoteDraft? initialDraft,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => NoteComposerDialog(
        ticker: ticker,
        existingNote: existingNote,
        initialDraft: initialDraft,
      ),
    );
  }

  @override
  ConsumerState<NoteComposerDialog> createState() => _NoteComposerDialogState();
}

class _NoteComposerDialogState extends ConsumerState<NoteComposerDialog> {
  late NoteDraft _draft = widget.existingNote != null
      ? NoteDraft.fromNote(widget.existingNote!)
      : (widget.initialDraft ?? NoteDraft.blank(ticker: widget.ticker));

  late final TextEditingController _titleController =
      TextEditingController(text: _draft.title);
  late final TextEditingController _contentController =
      TextEditingController(text: _draft.content);

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final actions = ref.read(labActionsProvider);
      final existing = widget.existingNote;
      if (existing == null) {
        await actions.createNote(_draft);
      } else {
        await actions.saveNote(existing.id, _draft);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = describeApiError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existingNote == null;

    return AlertDialog(
      title: Text(isNew ? 'Nueva nota sobre ${widget.ticker}' : 'Editar nota'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _titleController,
                autofocus: isNew,
                onChanged: (value) =>
                    setState(() => _draft = _draft.copyWith(title: value)),
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Título',
                  hintText: 'Tesis, seguimiento, recordatorio…',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _contentController,
                onChanged: (value) =>
                    setState(() => _draft = _draft.copyWith(content: value)),
                maxLines: 14,
                minLines: 8,
                style: AppTheme.numeric(fontSize: 13).copyWith(height: 1.5),
                decoration: const InputDecoration(
                  hintText: 'Escribí acá. Soporta Markdown.',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    _draft.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                    size: 15,
                    color:
                        _draft.pinned ? AppTheme.accent : AppTheme.textMuted,
                  ),
                  const SizedBox(width: 4),
                  const Text('Fijada', style: TextStyle(fontSize: 12)),
                  Switch(
                    value: _draft.pinned,
                    onChanged: (value) =>
                        setState(() => _draft = _draft.copyWith(pinned: value)),
                  ),
                  const Spacer(),
                  Text(
                    // Se dice a qué símbolo va a quedar vinculada: la nota se crea desde la ficha de
                    // un activo, y ese vínculo es lo que la hace reaparecer acá mañana.
                    'Vinculada a ${_draft.normalizedTicker ?? widget.ticker}',
                    style: AppTheme.numeric(
                      fontSize: 10,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style:
                      const TextStyle(color: AppTheme.bearish, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Guardando…' : 'Guardar'),
        ),
      ],
    );
  }
}

class _EmptyTickerNotes extends ConsumerWidget {
  const _EmptyTickerNotes({required this.ticker});

  final String ticker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 48),
      children: [
        const Icon(Icons.edit_note_outlined, size: 38, color: AppTheme.textMuted),
        const SizedBox(height: 14),
        Text(
          'Todavía no tenés notas sobre $ticker.\n'
          'Anotá tu tesis, el precio al que te interesaría entrar o qué esperás del próximo '
          'balance — y volvé a leerlo cuando el precio se mueva.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppTheme.textMuted, height: 1.45),
        ),
        const SizedBox(height: 18),
        Center(
          child: FilledButton.icon(
            onPressed: () =>
                NoteComposerDialog.show(context, ref, ticker: ticker),
            icon: const Icon(Icons.note_add_outlined, size: 16),
            label: Text('Escribir sobre $ticker'),
          ),
        ),
      ],
    );
  }
}
