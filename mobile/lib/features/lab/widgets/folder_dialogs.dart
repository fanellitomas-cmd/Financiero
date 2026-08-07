import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../data/folder.dart';
import '../presentation/lab_controller.dart';

/// Diálogos del árbol de carpetas: crear/renombrar, elegir destino y confirmar el borrado.

/// Pide un nombre de carpeta. Devuelve `null` si se canceló.
class FolderNameDialog extends StatefulWidget {
  const FolderNameDialog({
    super.key,
    required this.title,
    required this.confirmLabel,
    this.initialValue = '',
  });

  final String title;
  final String confirmLabel;
  final String initialValue;

  static Future<String?> show(
    BuildContext context, {
    required String title,
    required String confirmLabel,
    String initialValue = '',
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => FolderNameDialog(
        title: title,
        confirmLabel: confirmLabel,
        initialValue: initialValue,
      ),
    );
  }

  @override
  State<FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<FolderNameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    // Se valida acá y no solo contra el 422 del backend porque es el error más frecuente y no vale
    // gastar un round-trip: 120 es el largo de la columna (`app/models/folder.py`).
    if (name.isEmpty) {
      setState(() => _error = 'Escribí un nombre.');
      return;
    }
    if (name.length > 120) {
      setState(() => _error = 'Máximo 120 caracteres.');
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: 'Nombre',
            hintText: 'Research, Semiconductores, Tesis 2026…',
            errorText: _error,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

/// La carpeta elegida en el selector. Se envuelve en una clase porque `null` ya significa
/// "cancelaron", y hace falta poder distinguirlo de "eligieron la raíz".
@immutable
class FolderChoice {
  const FolderChoice(this.folderId);

  const FolderChoice.root() : folderId = null;

  final String? folderId;
}

/// Selector de carpeta destino, con el árbol indentado igual que el sidebar.
class FolderPickerDialog extends ConsumerWidget {
  const FolderPickerDialog({
    super.key,
    required this.title,
    required this.folders,
    this.excludeSubtreeOf,
    this.selectedFolderId,
    this.rootLabel = 'Raíz del Lab (sin carpeta)',
  });

  final String title;
  final List<Folder> folders;

  /// Se excluyen esta carpeta y todo su subárbol. Sirve para mover: una carpeta no puede ir dentro
  /// de sí misma ni de sus hijas, y el backend rechaza eso con 422 — mejor no ofrecerlo.
  final String? excludeSubtreeOf;

  final String? selectedFolderId;
  final String rootLabel;

  static Future<FolderChoice?> show(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    String? excludeSubtreeOf,
    String? selectedFolderId,
    String rootLabel = 'Raíz del Lab (sin carpeta)',
  }) {
    final folders = ref.read(foldersProvider).valueOrNull ?? const <Folder>[];
    return showDialog<FolderChoice>(
      context: context,
      builder: (_) => FolderPickerDialog(
        title: title,
        folders: folders,
        excludeSubtreeOf: excludeSubtreeOf,
        selectedFolderId: selectedFolderId,
        rootLabel: rootLabel,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = selectableFolders(folders, excludeSubtreeOf: excludeSubtreeOf);

    return AlertDialog(
      title: Text(title),
      contentPadding: const EdgeInsets.only(top: 12, bottom: 8),
      content: SizedBox(
        width: 380,
        height: 400,
        child: ListView(
          children: [
            ListTile(
              dense: true,
              selected: selectedFolderId == null,
              leading: const Icon(Icons.inbox_outlined, size: 18),
              title: Text(rootLabel, style: const TextStyle(fontSize: 13)),
              onTap: () =>
                  Navigator.of(context).pop(const FolderChoice.root()),
            ),
            const Divider(height: 1, color: AppTheme.border),
            if (options.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'No hay otras carpetas disponibles.',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                ),
              )
            else
              for (final folder in options)
                ListTile(
                  dense: true,
                  selected: folder.id == selectedFolderId,
                  contentPadding:
                      EdgeInsets.only(left: 16 + folder.depth * 14, right: 16),
                  leading: const Icon(Icons.folder_outlined, size: 17),
                  title: Text(
                    folder.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  onTap: () => Navigator.of(context).pop(FolderChoice(folder.id)),
                ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}

/// Las carpetas que se pueden elegir como destino.
///
/// Se excluye el subárbol completo de `excludeSubtreeOf` y no solo esa carpeta: mover "Research"
/// dentro de "Research / Semis" también cerraría un ciclo, aunque el destino sea otra fila.
///
/// El descarte se hace por `parentId` en cascada y no por el prefijo de `path`, que sería frágil: dos
/// carpetas hermanas llamadas "NVDA" y "NVDA histórico" comparten prefijo sin ser parientes.
List<Folder> selectableFolders(
  List<Folder> folders, {
  String? excludeSubtreeOf,
}) {
  if (excludeSubtreeOf == null) return folders;

  final excluded = <String>{excludeSubtreeOf};
  // La lista viene ordenada por ruta (profundidad creciente dentro de cada rama), así que una sola
  // pasada alcanza: cuando se llega a una hija, su padre ya se evaluó.
  for (final folder in folders) {
    final parent = folder.parentId;
    if (parent != null && excluded.contains(parent)) excluded.add(folder.id);
  }
  return folders.where((folder) => !excluded.contains(folder.id)).toList();
}

/// Confirma el borrado de una carpeta y devuelve si hay que hacerlo en cascada.
///
/// Devuelve `null` si se canceló, `false` para el borrado seguro (las notas vuelven a la raíz y las
/// subcarpetas suben un nivel) y `true` para la cascada.
///
/// El default es el seguro y la cascada es un check aparte porque el costo de los dos errores no es
/// simétrico: encontrar una nota en la raíz es una molestia, perder una tesis escrita a mano es
/// irreparable.
class FolderDeleteDialog extends StatefulWidget {
  const FolderDeleteDialog({super.key, required this.folder});

  final Folder folder;

  static Future<bool?> show(BuildContext context, Folder folder) {
    return showDialog<bool>(
      context: context,
      builder: (_) => FolderDeleteDialog(folder: folder),
    );
  }

  @override
  State<FolderDeleteDialog> createState() => _FolderDeleteDialogState();
}

class _FolderDeleteDialogState extends State<FolderDeleteDialog> {
  bool _cascade = false;

  @override
  Widget build(BuildContext context) {
    final folder = widget.folder;
    final hasContent = folder.noteCount > 0 || folder.subfolderCount > 0;

    return AlertDialog(
      title: Text('Eliminar «${folder.name}»'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              hasContent
                  ? _describeContent(folder)
                  : 'La carpeta está vacía.',
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 12),
            Text(
              _cascade
                  ? 'Se va a borrar la carpeta con TODO su contenido. No se puede deshacer.'
                  : 'Nada se pierde: las notas vuelven a la raíz del Lab y las subcarpetas suben '
                      'un nivel.',
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: _cascade ? AppTheme.bearish : AppTheme.textMuted,
              ),
            ),
            if (hasContent) ...[
              const SizedBox(height: 8),
              // `Row` + `Checkbox` en vez de `CheckboxListTile`: dentro de un `AlertDialog` con
              // ancho fijo el ListTile agrega su propio padding y descuadra el texto de arriba.
              Row(
                children: [
                  Checkbox(
                    value: _cascade,
                    onChanged: (value) =>
                        setState(() => _cascade = value ?? false),
                  ),
                  const Expanded(
                    child: Text(
                      'Borrar también las notas y subcarpetas de adentro',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: _cascade
              ? FilledButton.styleFrom(backgroundColor: AppTheme.bearish)
              : null,
          onPressed: () => Navigator.of(context).pop(_cascade),
          child: Text(_cascade ? 'Borrar todo' : 'Eliminar'),
        ),
      ],
    );
  }

  static String _describeContent(Folder folder) {
    final parts = <String>[
      if (folder.noteCount > 0)
        '${folder.noteCount} ${folder.noteCount == 1 ? "nota" : "notas"}',
      if (folder.subfolderCount > 0)
        '${folder.subfolderCount} '
            '${folder.subfolderCount == 1 ? "subcarpeta" : "subcarpetas"}',
    ];
    return 'Contiene ${parts.join(" y ")}.';
  }
}
