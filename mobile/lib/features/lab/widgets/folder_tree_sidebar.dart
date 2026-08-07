import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../data/folder.dart';
import '../presentation/lab_controller.dart';
import 'folder_dialogs.dart';

/// Sidebar de carpetas del Investment Lab, al estilo del panel izquierdo de un explorador de
/// archivos.
///
/// El árbol se dibuja como una lista plana indentada por `depth`, que es exactamente cómo lo manda
/// el backend. No hay estado de "expandido/colapsado" a propósito: un árbol de notas de inversión
/// tiene decenas de carpetas, no miles, y los nodos colapsados esconden justamente lo que se está
/// buscando. Se ve todo, indentado.
///
/// Arriba del árbol hay dos alcances que NO son carpetas y que por eso van separados por un divisor:
/// "Todas las notas" y "Sin carpeta". El segundo existe porque "las notas que todavía no organicé"
/// no se puede expresar eligiendo una carpeta.
class FolderTreeSidebar extends ConsumerWidget {
  const FolderTreeSidebar({super.key, this.onNavigate});

  /// Se llama después de elegir un alcance. En mobile el sidebar vive en un `Drawer` y hay que
  /// cerrarlo; en escritorio es un panel fijo y no hay nada que cerrar.
  final VoidCallback? onNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final foldersAsync = ref.watch(foldersProvider);
    final filter = ref.watch(labFilterProvider);
    final controller = ref.read(labFilterProvider.notifier);
    // Con un filtro de texto activo el total NO se muestra al lado del alcance: "Todas las notas —
    // 3" se lee como el tamaño de la biblioteca, y son los resultados de una búsqueda. Ese número
    // vive en el encabezado del explorador, donde va acompañado de los chips que lo explican.
    final notesTotal = ref.watch(labFilterProvider).hasTextFilters
        ? null
        : ref.watch(labNotesProvider).valueOrNull?.total;

    void select(void Function() action) {
      action();
      onNavigate?.call();
    }

    // `Material` y no `Container(color:)`: un `ColoredBox` entre el `Material` del Scaffold y los
    // `ListTile` del árbol tapa el fondo del seleccionado y los ink splashes — Flutter lo detecta y
    // lanza un assert. El color del panel tiene que venir de un Material propio.
    return Material(
      color: AppTheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SidebarHeader(
            onCreateRoot: () => _createFolder(context, ref, parent: null),
          ),
          const Divider(height: 1, color: AppTheme.border),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                _ScopeTile(
                  icon: Icons.all_inbox_outlined,
                  label: 'Todas las notas',
                  selected: filter.scope == LabScope.all,
                  // El conteo solo se muestra en el alcance activo: es el `total` del filtro que se
                  // pidió, y pintarlo al lado de un alcance que no está seleccionado diría un número
                  // de otra consulta.
                  count: filter.scope == LabScope.all ? notesTotal : null,
                  onTap: () => select(controller.selectAll),
                ),
                _ScopeTile(
                  icon: Icons.inbox_outlined,
                  label: 'Sin carpeta',
                  selected: filter.scope == LabScope.root,
                  count: filter.scope == LabScope.root ? notesTotal : null,
                  onTap: () => select(controller.selectRoot),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 6),
                  child: Text(
                    'CARPETAS',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ),
                ...foldersAsync.when(
                  data: (folders) => folders.isEmpty
                      ? [const _NoFoldersHint()]
                      : [
                          for (final folder in folders)
                            _FolderTile(
                              folder: folder,
                              selected: filter.scope == LabScope.folder &&
                                  filter.folderId == folder.id,
                              onTap: () =>
                                  select(() => controller.selectFolder(folder.id)),
                              onCreateChild: () =>
                                  _createFolder(context, ref, parent: folder),
                              onRename: () => _renameFolder(context, ref, folder),
                              onMove: () => _moveFolder(context, ref, folder),
                              onDelete: () => _deleteFolder(context, ref, folder),
                            ),
                        ],
                  loading: () => const [
                    Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                  ],
                  error: (error, stackTrace) => [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        describeApiError(error),
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _createFolder(
    BuildContext context,
    WidgetRef ref, {
    required Folder? parent,
  }) async {
    // El messenger se resuelve ANTES del `await`: es el patrón que evita usar un `BuildContext` que
    // puede haber quedado desmontado mientras el diálogo estaba abierto. El `ScaffoldMessengerState`
    // sobrevive al cierre del diálogo y del drawer, así que el aviso llega igual.
    final messenger = ScaffoldMessenger.of(context);
    final name = await FolderNameDialog.show(
      context,
      title: parent == null ? 'Nueva carpeta' : 'Nueva carpeta en «${parent.name}»',
      confirmLabel: 'Crear',
    );
    if (name == null) return;

    try {
      await ref.read(labActionsProvider).createFolder(name, parentId: parent?.id);
    } on Object catch (error) {
      _showError(messenger, error);
    }
  }

  Future<void> _renameFolder(
    BuildContext context,
    WidgetRef ref,
    Folder folder,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = await FolderNameDialog.show(
      context,
      title: 'Renombrar carpeta',
      initialValue: folder.name,
      confirmLabel: 'Guardar',
    );
    if (name == null || name == folder.name) return;

    try {
      await ref.read(labActionsProvider).renameFolder(folder.id, name);
    } on Object catch (error) {
      _showError(messenger, error);
    }
  }

  Future<void> _moveFolder(
    BuildContext context,
    WidgetRef ref,
    Folder folder,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final destination = await FolderPickerDialog.show(
      context,
      ref,
      title: 'Mover «${folder.name}»',
      // Una carpeta no puede mudarse dentro de sí misma ni de sus propias hijas: el backend lo
      // rechaza con 422, y ofrecerlo en la lista sería ofrecer un error.
      excludeSubtreeOf: folder.id,
      selectedFolderId: folder.parentId,
    );
    if (destination == null) return;

    try {
      await ref
          .read(labActionsProvider)
          .moveFolder(folder.id, parentId: destination.folderId);
    } on Object catch (error) {
      _showError(messenger, error);
    }
  }

  Future<void> _deleteFolder(
    BuildContext context,
    WidgetRef ref,
    Folder folder,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final cascade = await FolderDeleteDialog.show(context, folder);
    if (cascade == null) return;

    try {
      final result = await ref
          .read(labActionsProvider)
          .deleteFolder(folder.id, cascade: cascade);
      // El resumen del backend se muestra tal cual: por defecto no se pierde ninguna nota, y si no
      // se dice, el usuario asume que se fueron con la carpeta.
      messenger.showSnackBar(
        SnackBar(content: Text(result.describe(folder.name))),
      );
    } on Object catch (error) {
      _showError(messenger, error);
    }
  }

  void _showError(ScaffoldMessengerState messenger, Object error) {
    messenger.showSnackBar(
      SnackBar(content: Text(describeApiError(error))),
    );
  }
}

class _SidebarHeader extends StatelessWidget {
  const _SidebarHeader({required this.onCreateRoot});

  final VoidCallback onCreateRoot;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      child: Row(
        children: [
          const Icon(Icons.science_outlined, size: 18, color: AppTheme.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Investment Lab',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined, size: 20),
            tooltip: 'Nueva carpeta',
            onPressed: onCreateRoot,
          ),
        ],
      ),
    );
  }
}

class _NoFoldersHint extends StatelessWidget {
  const _NoFoldersHint();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Text(
        'Todavía no creaste carpetas. Tus notas viven en «Sin carpeta» hasta que las organices.',
        style: TextStyle(color: AppTheme.textMuted, fontSize: 11, height: 1.4),
      ),
    );
  }
}

/// Fila de un alcance que no es una carpeta ("Todas", "Sin carpeta").
class _ScopeTile extends StatelessWidget {
  const _ScopeTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      selected: selected,
      leading: Icon(icon, size: 18),
      title: Text(label, style: const TextStyle(fontSize: 13)),
      trailing: count == null ? null : _CountBadge(count: count!),
      onTap: onTap,
    );
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.folder,
    required this.selected,
    required this.onTap,
    required this.onCreateChild,
    required this.onRename,
    required this.onMove,
    required this.onDelete,
  });

  final Folder folder;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onCreateChild;
  final VoidCallback onRename;
  final VoidCallback onMove;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      selected: selected,
      // La indentación es lo único que comunica la jerarquía en una lista plana, así que sale
      // directo de `depth` — 14px por nivel, suficiente para leerse sin dejar las carpetas
      // profundas contra el borde derecho.
      contentPadding: EdgeInsets.only(left: 16 + folder.depth * 14, right: 4),
      leading: Icon(
        folder.subfolderCount > 0 ? Icons.folder_copy_outlined : Icons.folder_outlined,
        size: 17,
        color: selected ? AppTheme.accent : AppTheme.textMuted,
      ),
      title: Text(
        folder.name,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // El conteo se muestra siempre (no solo en la carpeta activa) porque acá sí es un dato
          // propio de la carpeta que el backend calcula por fila, no el total de una consulta.
          if (folder.noteCount > 0) _CountBadge(count: folder.noteCount),
          PopupMenuButton<_FolderAction>(
            tooltip: 'Opciones de ${folder.name}',
            icon: const Icon(Icons.more_horiz, size: 16),
            padding: EdgeInsets.zero,
            onSelected: (action) => switch (action) {
              _FolderAction.newSubfolder => onCreateChild(),
              _FolderAction.rename => onRename(),
              _FolderAction.move => onMove(),
              _FolderAction.delete => onDelete(),
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _FolderAction.newSubfolder,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(Icons.create_new_folder_outlined, size: 18),
                  title: Text('Nueva subcarpeta'),
                ),
              ),
              PopupMenuItem(
                value: _FolderAction.rename,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(Icons.drive_file_rename_outline, size: 18),
                  title: Text('Renombrar'),
                ),
              ),
              PopupMenuItem(
                value: _FolderAction.move,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(Icons.drive_file_move_outline, size: 18),
                  title: Text('Mover'),
                ),
              ),
              PopupMenuItem(
                value: _FolderAction.delete,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(Icons.delete_outline, size: 18),
                  title: Text('Eliminar'),
                ),
              ),
            ],
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

enum _FolderAction { newSubfolder, rename, move, delete }

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: Text(
        '$count',
        style: AppTheme.numeric(fontSize: 10, color: AppTheme.textMuted),
      ),
    );
  }
}
