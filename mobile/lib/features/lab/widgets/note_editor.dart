import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../data/note.dart';
import '../data/note_formatting.dart';
import '../presentation/lab_controller.dart';
import 'attachment_card.dart';
import 'folder_dialogs.dart';
import 'markdown_view.dart';
import 'note_explorer.dart' show TickerBadge;

/// Editor/visor de una nota del Investment Lab.
///
/// Guarda con un botón explícito y NO en cada tecla. Un autoguardado por pulsación sobre un cuerpo de
/// 40 KB serían decenas de PATCH por párrafo, y peor: dejaría cada estado intermedio de un texto que
/// se está pensando como la versión oficial de la nota. En cambio se muestra siempre si hay cambios
/// sin guardar, y se avisa antes de perderlos.
class NoteEditorPanel extends ConsumerWidget {
  const NoteEditorPanel({super.key, required this.target});

  final LabEditorTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (target.isNew) {
      return _NoteEditorForm(
        // La `key` es lo que fuerza un `State` nuevo al cambiar de nota. Sin ella, abrir otra nota
        // reusaría los `TextEditingController` con el texto de la anterior — y el primer "Guardar"
        // escribiría el cuerpo equivocado.
        key: const ValueKey('lab-editor-new'),
        note: null,
        initialDraft: target.draft ?? NoteDraft.blank(),
      );
    }

    final noteId = target.noteId!;
    final noteAsync = ref.watch(noteDetailProvider(noteId));

    return noteAsync.when(
      data: (note) => _NoteEditorForm(
        // La `key` lleva SOLO el id y no la fecha de edición: si cambiara al guardar, el formulario
        // se reconstruiría entero después de cada guardado y el cursor volvería al principio del
        // texto. Con el id alcanza — el `State` sobrevive al refetch y `widget.note` se actualiza
        // solo, que es justo lo que necesita el cálculo de "sin guardar".
        key: ValueKey('lab-editor-$noteId'),
        note: note,
        initialDraft: NoteDraft.fromNote(note),
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined,
                  size: 34, color: AppTheme.textMuted),
              const SizedBox(height: 12),
              Text(describeApiError(error), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => ref.invalidate(noteDetailProvider(noteId)),
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoteEditorForm extends ConsumerStatefulWidget {
  const _NoteEditorForm({
    super.key,
    required this.note,
    required this.initialDraft,
  });

  /// `null` cuando la nota todavía no existe en el servidor.
  final Note? note;

  final NoteDraft initialDraft;

  @override
  ConsumerState<_NoteEditorForm> createState() => _NoteEditorFormState();
}

class _NoteEditorFormState extends ConsumerState<_NoteEditorForm> {
  late NoteDraft _draft = widget.initialDraft;
  late final TextEditingController _titleController =
      TextEditingController(text: widget.initialDraft.title);
  late final TextEditingController _contentController =
      TextEditingController(text: widget.initialDraft.content);
  late final TextEditingController _tickerController =
      TextEditingController(text: widget.initialDraft.ticker ?? '');

  bool _preview = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // El flag global arranca reflejando el estado real de este formulario: una nota nueva con
    // contenido ya insertado (la síntesis de la Ficha, por ejemplo) nace sucia.
    WidgetsBinding.instance.addPostFrameCallback((_) => _publishDirty());
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _tickerController.dispose();
    super.dispose();
  }

  /// ¿Hay cambios sin guardar?
  ///
  /// Para una nota existente se compara contra lo que está en el servidor, así que escribir una
  /// palabra y borrarla vuelve a dejar el editor limpio. Para una nota nueva, cualquier cosa escrita
  /// cuenta: nada de eso existe todavía en ninguna parte.
  bool get _isDirty {
    final note = widget.note;
    if (note == null) {
      return _draft.title.trim().isNotEmpty ||
          _draft.content.isNotEmpty ||
          _draft.normalizedTicker != null ||
          _draft.folderId != null ||
          _draft.pinned;
    }
    return _draft.differsFrom(note);
  }

  void _publishDirty() {
    if (!mounted) return;
    ref.read(labEditorDirtyProvider.notifier).state = _isDirty;
  }

  void _update(NoteDraft next) {
    setState(() {
      _draft = next;
      _error = null;
    });
    _publishDirty();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final actions = ref.read(labActionsProvider);
      final note = widget.note;
      if (note == null) {
        final created = await actions.createNote(_draft);
        if (!mounted) return;
        // Al crearla, el editor pasa a apuntar a la nota real: sin esto, el siguiente "Guardar"
        // crearía una segunda copia en vez de actualizar la primera.
        ref.read(labEditorTargetProvider.notifier).state =
            LabEditorTarget.existing(created.id);
      } else {
        await actions.saveNote(note.id, _draft);
      }
      if (!mounted) return;
      ref.read(labEditorDirtyProvider.notifier).state = false;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Nota guardada.')));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = describeApiError(error);
      });
    }
  }

  Future<void> _pickFolder() async {
    final choice = await FolderPickerDialog.show(
      context,
      ref,
      title: 'Archivar la nota',
      selectedFolderId: _draft.folderId,
    );
    if (choice == null) return;
    _update(
      choice.folderId == null
          ? _draft.copyWith(clearFolder: true)
          : _draft.copyWith(folderId: choice.folderId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final folders = ref.watch(foldersByIdProvider);
    final folderPath =
        _draft.folderId == null ? null : folders[_draft.folderId]?.path;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _EditorToolbar(
          isNew: widget.note == null,
          isDirty: _isDirty,
          saving: _saving,
          preview: _preview,
          onTogglePreview: (value) => setState(() => _preview = value),
          onSave: _isDirty && !_saving ? _save : null,
          onClose: () => _closeEditor(context),
        ),
        const Divider(height: 1, color: AppTheme.border),
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
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              TextField(
                controller: _titleController,
                onChanged: (value) => _update(_draft.copyWith(title: value)),
                style: Theme.of(context).textTheme.titleLarge,
                decoration: const InputDecoration(
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: 'Título de la nota',
                ),
              ),
              const SizedBox(height: 10),
              _MetaRow(
                folderPath: folderPath,
                tickerController: _tickerController,
                onPickFolder: _pickFolder,
                onClearFolder: _draft.folderId == null
                    ? null
                    : () => _update(_draft.copyWith(clearFolder: true)),
                onTickerChanged: (value) => _update(
                  value.trim().isEmpty
                      ? _draft.copyWith(clearTicker: true)
                      : _draft.copyWith(ticker: value),
                ),
                pinned: _draft.pinned,
                onPinnedChanged: (value) =>
                    _update(_draft.copyWith(pinned: value)),
              ),
              const SizedBox(height: 14),
              const Divider(height: 1, color: AppTheme.border),
              const SizedBox(height: 14),
              if (_preview)
                MarkdownView(source: _draft.content)
              else
                TextField(
                  controller: _contentController,
                  onChanged: (value) => _update(_draft.copyWith(content: value)),
                  maxLines: null,
                  minLines: 14,
                  keyboardType: TextInputType.multiline,
                  // Monoespaciada mientras se edita: el markdown se escribe alineando viñetas y
                  // bloques de código, y con una proporcional esa alineación no se ve.
                  style: AppTheme.numeric(fontSize: 13.5).copyWith(height: 1.5),
                  decoration: const InputDecoration(
                    hintText:
                        'Escribí tu tesis…\n\nSoporta Markdown: # títulos, - viñetas, **negrita**, '
                        '> citas y bloques de código.',
                    alignLabelWithHint: true,
                  ),
                ),
              // Las capturas van DEBAJO del cuerpo y solo cuando la nota ya existe: una nota que
              // todavía no se guardó no tiene id contra el cual adjuntar nada.
              if (widget.note != null) ...[
                const SizedBox(height: 18),
                NoteAttachmentsSection(noteId: widget.note!.id),
              ],
              const SizedBox(height: 16),
              _EditorFooter(note: widget.note, draft: _draft),
            ],
          ),
        ),
      ],
    );
  }

  void _closeEditor(BuildContext context) {
    ref.read(labEditorDirtyProvider.notifier).state = false;
    ref.read(labEditorTargetProvider.notifier).state = null;
    // En mobile el editor es una ruta propia; en escritorio es el panel derecho y no hay nada que
    // desapilar. `maybePop` cubre los dos casos sin que el editor tenga que saber en cuál está.
    Navigator.of(context).maybePop();
  }
}

class _EditorToolbar extends StatelessWidget {
  const _EditorToolbar({
    required this.isNew,
    required this.isDirty,
    required this.saving,
    required this.preview,
    required this.onTogglePreview,
    required this.onSave,
    required this.onClose,
  });

  final bool isNew;
  final bool isDirty;
  final bool saving;
  final bool preview;
  final ValueChanged<bool> onTogglePreview;
  final VoidCallback? onSave;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            tooltip: 'Cerrar el editor',
            onPressed: onClose,
          ),
          if (isNew)
            const _StatusPill(label: 'NUEVA', color: AppTheme.accent)
          else if (isDirty)
            // El indicador de "sin guardar" es lo que hace honesto al guardado explícito: sin él, el
            // usuario no tiene forma de saber que lo que ve en pantalla no está en el servidor.
            const _StatusPill(label: 'SIN GUARDAR', color: AppTheme.neutral)
          else
            const _StatusPill(label: 'GUARDADA', color: AppTheme.textMuted),
          const Spacer(),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(Icons.edit_outlined, size: 15),
                label: Text('Editar'),
              ),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.visibility_outlined, size: 15),
                label: Text('Vista'),
              ),
            ],
            selected: {preview},
            onSelectionChanged: (selection) => onTogglePreview(selection.first),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: onSave,
            icon: saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined, size: 16),
            label: const Text('Guardar'),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: AppTheme.badgeDecoration(color),
      child: Text(
        label,
        style: AppTheme.numeric(fontSize: 9, color: color)
            .copyWith(fontWeight: FontWeight.bold, letterSpacing: 0.6),
      ),
    );
  }
}

/// Carpeta, ticker y fijado. Los tres son metadatos independientes de la nota y van juntos arriba del
/// cuerpo porque son lo que decide dónde la vas a volver a encontrar.
class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.folderPath,
    required this.tickerController,
    required this.onPickFolder,
    required this.onClearFolder,
    required this.onTickerChanged,
    required this.pinned,
    required this.onPinnedChanged,
  });

  final String? folderPath;
  final TextEditingController tickerController;
  final VoidCallback onPickFolder;
  final VoidCallback? onClearFolder;
  final ValueChanged<String> onTickerChanged;
  final bool pinned;
  final ValueChanged<bool> onPinnedChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          onPressed: onPickFolder,
          icon: const Icon(Icons.folder_outlined, size: 15),
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Text(
              // "Sin carpeta" y no un botón vacío: la raíz del Lab es un lugar real donde la nota
              // vive, no la ausencia de una elección.
              folderPath ?? 'Sin carpeta',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
        if (onClearFolder != null)
          IconButton(
            iconSize: 15,
            visualDensity: VisualDensity.compact,
            tooltip: 'Sacar de la carpeta',
            icon: const Icon(Icons.folder_off_outlined),
            onPressed: onClearFolder,
          ),
        SizedBox(
          width: 130,
          child: TextField(
            controller: tickerController,
            textCapitalization: TextCapitalization.characters,
            onChanged: onTickerChanged,
            style: AppTheme.numeric(fontSize: 13),
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Ticker',
              hintText: 'NVDA',
            ),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              pinned ? Icons.push_pin : Icons.push_pin_outlined,
              size: 15,
              color: pinned ? AppTheme.accent : AppTheme.textMuted,
            ),
            const SizedBox(width: 4),
            const Text('Fijada', style: TextStyle(fontSize: 12)),
            // `Switch` suelto y no `SwitchListTile`: el ListTile exige un ancho definido y dentro de
            // un `Wrap` no lo tiene.
            Switch(value: pinned, onChanged: onPinnedChanged),
          ],
        ),
      ],
    );
  }
}

class _EditorFooter extends StatelessWidget {
  const _EditorFooter({required this.note, required this.draft});

  final Note? note;
  final NoteDraft draft;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      formatContentLength(draft.content.length),
      if (note != null) 'creada ${formatRelativeTime(note!.createdAt)}',
      if (note != null) 'editada ${formatRelativeTime(note!.updatedAt)}',
    ];

    return Row(
      children: [
        Expanded(
          child: Text(
            parts.join(' · '),
            style: AppTheme.numeric(fontSize: 10, color: AppTheme.textMuted),
          ),
        ),
        if (draft.normalizedTicker != null)
          TickerBadge(ticker: draft.normalizedTicker!),
      ],
    );
  }
}
