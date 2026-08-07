import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../data/note.dart';
import '../data/note_formatting.dart';
import '../presentation/lab_controller.dart';
import 'folder_dialogs.dart';

/// Modo de visualización del explorador. La lista prioriza el `excerpt` (más texto por fila) y la
/// grilla prioriza cuántas notas se ven de una (más ítems por pantalla). Cuál conviene depende de si
/// estás buscando algo por su contenido o escaneando lo que tenés.
enum NoteViewMode { list, grid }

/// El modo elegido. Arranca en lista: cuando todavía hay pocas notas, el `excerpt` completo es más
/// útil que ver muchas tarjetas casi vacías.
final noteViewModeProvider =
    StateProvider<NoteViewMode>((ref) => NoteViewMode.list);

/// Panel central del Investment Lab: la lista de notas del alcance activo, con búsqueda por texto en
/// tiempo real y filtro por ticker.
class NoteExplorer extends ConsumerWidget {
  const NoteExplorer({
    super.key,
    required this.onOpenNote,
    required this.onCreateNote,
  });

  final ValueChanged<String> onOpenNote;
  final VoidCallback onCreateNote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notesAsync = ref.watch(labNotesProvider);
    final filter = ref.watch(labFilterProvider);
    final folders = ref.watch(foldersByIdProvider);

    return Column(
      children: [
        _ExplorerToolbar(onCreateNote: onCreateNote),
        const Divider(height: 1, color: AppTheme.border),
        Expanded(
          child: notesAsync.when(
            data: (page) => page.items.isEmpty
                ? _EmptyExplorer(filter: filter)
                : RefreshIndicator(
                    onRefresh: () async => ref.invalidate(notesProvider),
                    child: _NoteCollection(
                      page: page,
                      folderNames: {
                        for (final entry in folders.entries)
                          entry.key: entry.value.name,
                      },
                      onOpenNote: onOpenNote,
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
                      onPressed: () => ref.invalidate(notesProvider),
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

class _ExplorerToolbar extends ConsumerStatefulWidget {
  const _ExplorerToolbar({required this.onCreateNote});

  final VoidCallback onCreateNote;

  @override
  ConsumerState<_ExplorerToolbar> createState() => _ExplorerToolbarState();
}

class _ExplorerToolbarState extends ConsumerState<_ExplorerToolbar> {
  final _queryController = TextEditingController();
  final _tickerController = TextEditingController();

  @override
  void dispose() {
    _queryController.dispose();
    _tickerController.dispose();
    super.dispose();
  }

  void _clearAll() {
    _queryController.clear();
    _tickerController.clear();
    ref.read(labFilterProvider.notifier).clearTextFilters();
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(labFilterProvider);
    final viewMode = ref.watch(noteViewModeProvider);
    final total = ref.watch(labNotesProvider).valueOrNull?.total;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _queryController,
                  // La búsqueda se dispara sola mientras se escribe, con debounce en el controller:
                  // un request por tecla serían diez consultas para "margen bruto", nueve de ellas
                  // de frases que nadie buscó.
                  onChanged: ref.read(labFilterProvider.notifier).setQuery,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                    // Hint corto a propósito: el explorador vive en un panel de ~380px con cuatro
                    // controles en la fila, y un texto largo se corta en "Busca…", que no dice nada.
                    // Qué busca (título y cuerpo) lo aclara el vacío cuando no hay resultados.
                    hintText: 'Buscar…',
                    suffixIcon: filter.hasTextFilters
                        ? IconButton(
                            icon: const Icon(Icons.close, size: 16),
                            tooltip: 'Limpiar filtros',
                            onPressed: _clearAll,
                          )
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 92,
                child: TextField(
                  controller: _tickerController,
                  textCapitalization: TextCapitalization.characters,
                  onChanged: ref.read(labFilterProvider.notifier).setTicker,
                  style: AppTheme.numeric(fontSize: 13),
                  // Sin ícono decorativo: en 92px el prefijo se comía un tercio del campo y dejaba
                  // el hint en "Tick…". La palabra "Ticker" dice más que cualquier ícono.
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Ticker',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _ViewModeToggle(
                mode: viewMode,
                onChanged: (mode) =>
                    ref.read(noteViewModeProvider.notifier).state = mode,
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.note_add_outlined),
                tooltip: 'Nueva nota',
                onPressed: widget.onCreateNote,
              ),
            ],
          ),
          const SizedBox(height: 8),
          _ScopeSummary(filter: filter, total: total),
        ],
      ),
    );
  }
}

/// Dice en una línea qué se está mirando y cuántas notas hay.
///
/// Existe porque con tres filtros combinables (alcance, ticker, texto) una lista corta es ambigua:
/// "3 notas" puede ser toda tu biblioteca o el resultado de un filtro que quedó puesto sin querer.
class _ScopeSummary extends ConsumerWidget {
  const _ScopeSummary({required this.filter, required this.total});

  final LabFilter filter;
  final int? total;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folder = filter.folderId == null
        ? null
        : ref.watch(foldersByIdProvider)[filter.folderId];

    final scopeLabel = switch (filter.scope) {
      LabScope.all => 'Todas las notas',
      LabScope.root => 'Notas sin carpeta',
      LabScope.folder => folder?.path ?? 'Carpeta',
    };

    return Row(
      children: [
        Expanded(
          child: Text(
            scopeLabel,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        if (filter.ticker != null) ...[
          _FilterChip(
            label: filter.ticker!,
            icon: Icons.sell_outlined,
            monospace: true,
          ),
          const SizedBox(width: 6),
        ],
        if (filter.query != null) ...[
          _FilterChip(label: '"${filter.query!}"', icon: Icons.search),
          const SizedBox(width: 6),
        ],
        if (total != null)
          Text(
            '$total',
            style: AppTheme.numeric(fontSize: 12, color: AppTheme.textMuted),
          ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.icon,
    this.monospace = false,
  });

  final String label;
  final IconData icon;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: AppTheme.badgeDecoration(AppTheme.accent),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: AppTheme.accent),
          const SizedBox(width: 4),
          Text(
            label,
            style: monospace
                ? AppTheme.numeric(fontSize: 10, color: AppTheme.accent)
                : const TextStyle(fontSize: 10, color: AppTheme.accent),
          ),
        ],
      ),
    );
  }
}

class _ViewModeToggle extends StatelessWidget {
  const _ViewModeToggle({required this.mode, required this.onChanged});

  final NoteViewMode mode;
  final ValueChanged<NoteViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final option in NoteViewMode.values)
          IconButton(
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            tooltip: option == NoteViewMode.list ? 'Ver en lista' : 'Ver en grilla',
            icon: Icon(
              option == NoteViewMode.list
                  ? Icons.view_list_outlined
                  : Icons.grid_view_outlined,
              color: option == mode ? AppTheme.accent : AppTheme.textMuted,
            ),
            onPressed: () => onChanged(option),
          ),
      ],
    );
  }
}

class _NoteCollection extends ConsumerWidget {
  const _NoteCollection({
    required this.page,
    required this.folderNames,
    required this.onOpenNote,
  });

  final NotePage page;
  final Map<String, String> folderNames;
  final ValueChanged<String> onOpenNote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(noteViewModeProvider);
    final openNoteId = ref.watch(labEditorTargetProvider)?.noteId;

    final footer = page.hasMore
        // Se dice explícitamente que la lista está truncada. Sin esto, "50 de 180" se leería como
        // "tengo 50 notas" y la búsqueda de una nota vieja parecería fallar.
        ? _TruncationNotice(shown: page.items.length, total: page.total)
        : null;

    if (mode == NoteViewMode.grid) {
      return GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          // `MaxCrossAxisExtent` y no una cantidad fija de columnas: el explorador vive en un panel
          // cuyo ancho cambia con la ventana, y una grilla de 3 columnas fijas dejaría tarjetas de
          // 90px en el layout angosto.
          maxCrossAxisExtent: 260,
          mainAxisExtent: 148,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: page.items.length + (footer != null ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= page.items.length) return footer!;
          final note = page.items[index];
          return _NoteCard(
            note: note,
            folderName: note.folderId == null ? null : folderNames[note.folderId],
            selected: note.id == openNoteId,
            onTap: () => onOpenNote(note.id),
          );
        },
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: page.items.length + (footer != null ? 1 : 0),
      separatorBuilder: (context, index) =>
          const Divider(height: 1, color: AppTheme.border),
      itemBuilder: (context, index) {
        if (index >= page.items.length) return footer!;
        final note = page.items[index];
        return _NoteRow(
          note: note,
          folderName: note.folderId == null ? null : folderNames[note.folderId],
          selected: note.id == openNoteId,
          onTap: () => onOpenNote(note.id),
        );
      },
    );
  }
}

/// Acciones rápidas comunes a la fila y a la tarjeta.
class _NoteActionsMenu extends ConsumerWidget {
  const _NoteActionsMenu({required this.note, this.iconSize = 18});

  final NoteSummary note;
  final double iconSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<_NoteAction>(
      tooltip: 'Opciones de ${note.title}',
      icon: Icon(Icons.more_vert, size: iconSize),
      padding: EdgeInsets.zero,
      onSelected: (action) async {
        final actions = ref.read(labActionsProvider);
        try {
          switch (action) {
            case _NoteAction.togglePin:
              await actions.togglePinned(note.id, pinned: !note.pinned);
            case _NoteAction.move:
              final choice = await FolderPickerDialog.show(
                context,
                ref,
                title: 'Mover «${note.title}»',
                selectedFolderId: note.folderId,
              );
              if (choice == null) return;
              await actions.moveNote(note.id, folderId: choice.folderId);
            case _NoteAction.delete:
              final confirmed = await _confirmDelete(context, note);
              if (!confirmed) return;
              await actions.deleteNote(note.id);
          }
        } on Object catch (error) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(describeApiError(error))),
          );
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _NoteAction.togglePin,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(
              note.pinned ? Icons.push_pin_outlined : Icons.push_pin,
              size: 18,
            ),
            title: Text(note.pinned ? 'Dejar de fijar' : 'Fijar arriba'),
          ),
        ),
        const PopupMenuItem(
          value: _NoteAction.move,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(Icons.drive_file_move_outline, size: 18),
            title: Text('Mover a carpeta'),
          ),
        ),
        const PopupMenuItem(
          value: _NoteAction.delete,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(Icons.delete_outline, size: 18),
            title: Text('Eliminar'),
          ),
        ),
      ],
    );
  }

  static Future<bool> _confirmDelete(
    BuildContext context,
    NoteSummary note,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Eliminar nota'),
        content: Text(
          'Se va a borrar «${note.title}». No se puede deshacer.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.bearish),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}

enum _NoteAction { togglePin, move, delete }

class _NoteRow extends StatelessWidget {
  const _NoteRow({
    required this.note,
    required this.folderName,
    required this.selected,
    required this.onTap,
  });

  final NoteSummary note;
  final String? folderName;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      selected: selected,
      onTap: onTap,
      title: Row(
        children: [
          if (note.pinned) ...[
            const Icon(Icons.push_pin, size: 13, color: AppTheme.accent),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              note.title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          if (note.ticker != null) ...[
            const SizedBox(width: 8),
            TickerBadge(ticker: note.ticker!),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 3),
          Text(
            // Se muestra el `excerpt` que manda el backend, no un recorte del cuerpo: el listado no
            // trae el cuerpo justamente para no bajarlo.
            note.excerpt.isEmpty ? 'Sin contenido' : note.excerpt,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: AppTheme.textMuted,
              fontStyle: note.excerpt.isEmpty ? FontStyle.italic : null,
            ),
          ),
          const SizedBox(height: 4),
          _NoteMetaLine(note: note, folderName: folderName),
        ],
      ),
      trailing: _NoteActionsMenu(note: note),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({
    required this.note,
    required this.folderName,
    required this.selected,
    required this.onTap,
  });

  final NoteSummary note;
  final String? folderName;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radius),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(AppTheme.radius),
          border: Border.all(
            color: selected ? AppTheme.accent : AppTheme.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (note.pinned) ...[
                  const Icon(Icons.push_pin, size: 12, color: AppTheme.accent),
                  const SizedBox(width: 5),
                ],
                Expanded(
                  child: Text(
                    note.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                ),
                _NoteActionsMenu(note: note, iconSize: 15),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Text(
                note.excerpt.isEmpty ? 'Sin contenido' : note.excerpt,
                overflow: TextOverflow.ellipsis,
                maxLines: 3,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.35,
                  color: AppTheme.textMuted,
                  fontStyle: note.excerpt.isEmpty ? FontStyle.italic : null,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                if (note.ticker != null) ...[
                  TickerBadge(ticker: note.ticker!),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    formatRelativeTime(note.updatedAt),
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.numeric(
                      fontSize: 10,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NoteMetaLine extends StatelessWidget {
  const _NoteMetaLine({required this.note, required this.folderName});

  final NoteSummary note;
  final String? folderName;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      formatRelativeTime(note.updatedAt),
      formatContentLength(note.contentLength),
      // "Sin carpeta" se dice explícitamente en vez de dejar el hueco: con el alcance "Todas", una
      // fila sin dato de carpeta sería indistinguible de una cuyo nombre no se pudo resolver.
      folderName ?? 'Sin carpeta',
    ];

    return Text(
      parts.join(' · '),
      style: AppTheme.numeric(fontSize: 10, color: AppTheme.textMuted),
    );
  }
}

/// Insignia del símbolo vinculado a la nota.
///
/// Monoespaciada como todos los tickers de la app: es el ancla visual que deja escanear una lista
/// mezclada y ver de un vistazo qué notas son de qué activo.
class TickerBadge extends StatelessWidget {
  const TickerBadge({super.key, required this.ticker, this.fontSize = 10});

  final String ticker;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: AppTheme.badgeDecoration(AppTheme.accent),
      child: Text(
        ticker,
        style: AppTheme.numeric(fontSize: fontSize, color: AppTheme.accent)
            .copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _TruncationNotice extends StatelessWidget {
  const _TruncationNotice({required this.shown, required this.total});

  final int shown;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        'Mostrando $shown de $total notas. Afiná la búsqueda para encontrar el resto.',
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
      ),
    );
  }
}

/// Vacío del explorador.
///
/// Tres mensajes distintos y no uno genérico: "no tengo notas", "esta carpeta está vacía" y "el
/// filtro no encontró nada" piden acciones opuestas, y un único "sin resultados" haría que un filtro
/// olvidado parezca una biblioteca vacía.
class _EmptyExplorer extends ConsumerWidget {
  const _EmptyExplorer({required this.filter});

  final LabFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (icon, message) = switch (filter) {
      LabFilter(hasTextFilters: true) => (
          Icons.search_off,
          'Ningún resultado con esos filtros. Probá con otras palabras o limpialos con la ✕.',
        ),
      LabFilter(scope: LabScope.folder) => (
          Icons.folder_open_outlined,
          'Esta carpeta está vacía. Creá una nota con el botón + y quedará archivada acá.',
        ),
      LabFilter(scope: LabScope.root) => (
          Icons.inbox_outlined,
          'No tenés notas sueltas: todas están archivadas en alguna carpeta.',
        ),
      _ => (
          Icons.science_outlined,
          'Todavía no escribiste ninguna nota. El Lab es para tus tesis, seguimientos y '
              'recordatorios sobre cada activo.',
        ),
    };

    return ListView(
      // ListView y no Center para que el RefreshIndicator siga funcionando estando vacío.
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
      children: [
        Icon(icon, size: 38, color: AppTheme.textMuted),
        const SizedBox(height: 14),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppTheme.textMuted, height: 1.45),
        ),
      ],
    );
  }
}
