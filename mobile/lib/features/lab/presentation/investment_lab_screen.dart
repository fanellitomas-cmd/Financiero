import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/app_theme.dart';
import '../data/note.dart';
import '../widgets/folder_tree_sidebar.dart';
import '../widgets/note_editor.dart';
import '../widgets/note_explorer.dart';
import 'lab_controller.dart';

/// Pantalla del Investment Lab: notas de investigación organizadas en carpetas, con la disposición
/// de un explorador de archivos.
///
/// Tres paneles y un layout que se adapta al ancho, porque los tres no caben en un teléfono:
///
///   - **≥ `masterDetail` (1100px):** carpetas | explorador | editor, los tres a la vista. Es el modo
///     para el que la pantalla está pensada: elegir una carpeta, escanear sus notas y escribir sin
///     perder de vista dónde estás.
///   - **≥ `desktop` (768px):** carpetas | explorador. El editor no entra como tercera columna sin
///     dejar las tres ilegibles, así que se abre como pantalla completa.
///   - **abajo de eso:** solo el explorador; las carpetas viven en un `Drawer`. Un sidebar fijo en un
///     teléfono se come la mitad del ancho de la lista que uno vino a leer.
class InvestmentLabScreen extends ConsumerWidget {
  const InvestmentLabScreen({super.key});

  static const double _sidebarWidth = 250;
  static const double _explorerWidth = 380;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(labEditorTargetProvider);

    if (context.isMasterDetail) {
      return Scaffold(
        body: Row(
          children: [
            const SizedBox(width: _sidebarWidth, child: FolderTreeSidebar()),
            const VerticalDivider(width: 1, thickness: 1, color: AppTheme.border),
            SizedBox(
              width: _explorerWidth,
              child: NoteExplorer(
                onOpenNote: (noteId) => openNoteInLab(context, ref, noteId),
                onCreateNote: () => createNoteInLab(context, ref),
              ),
            ),
            const VerticalDivider(width: 1, thickness: 1, color: AppTheme.border),
            Expanded(
              child: target == null
                  ? const _EditorPlaceholder()
                  : NoteEditorPanel(target: target),
            ),
          ],
        ),
      );
    }

    if (context.isDesktop) {
      return Scaffold(
        body: Row(
          children: [
            const SizedBox(width: _sidebarWidth, child: FolderTreeSidebar()),
            const VerticalDivider(width: 1, thickness: 1, color: AppTheme.border),
            Expanded(
              child: NoteExplorer(
                onOpenNote: (noteId) => openNoteInLab(context, ref, noteId),
                onCreateNote: () => createNoteInLab(context, ref),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Investment Lab'),
        // El sidebar de carpetas es el `Drawer` en mobile: el ícono de hamburguesa lo abre.
      ),
      drawer: const Drawer(
        width: 280,
        backgroundColor: AppTheme.surface,
        child: SafeArea(child: _DrawerSidebar()),
      ),
      body: NoteExplorer(
        onOpenNote: (noteId) => openNoteInLab(context, ref, noteId),
        onCreateNote: () => createNoteInLab(context, ref),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Nueva nota',
        onPressed: () => createNoteInLab(context, ref),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _DrawerSidebar extends StatelessWidget {
  const _DrawerSidebar();

  @override
  Widget build(BuildContext context) {
    return FolderTreeSidebar(
      // Elegir una carpeta cierra el drawer: dejarlo abierto taparía la lista que se acaba de
      // filtrar, que es exactamente lo que el usuario quería ver.
      onNavigate: () => Navigator.of(context).maybePop(),
    );
  }
}

/// Abre una nota en el editor.
///
/// En master-detail llena el panel derecho (la lista queda a la vista para saltar entre notas); en
/// pantallas más angostas navega a `/lab/note/{id}` como pantalla completa. Es la misma regla que ya
/// usa la Watchlist con la ficha de un activo, para que el gesto signifique lo mismo en las dos.
Future<void> openNoteInLab(
  BuildContext context,
  WidgetRef ref,
  String noteId,
) async {
  if (!await _confirmDiscardIfDirty(context, ref)) return;
  ref.read(labEditorTargetProvider.notifier).state =
      LabEditorTarget.existing(noteId);
  // El chequeo de `mounted` va ANTES de leer el ancho: `isMasterDetail` consulta el `MediaQuery` del
  // context, y después de un diálogo el widget puede haber desaparecido.
  if (!context.mounted) return;
  if (context.isMasterDetail) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const NoteEditorScreen()),
  );
}

/// Crea una nota nueva, ya ubicada en el contexto en el que se está trabajando.
///
/// La carpeta y el ticker del filtro activo se heredan: crear una nota estando dentro de
/// "Semiconductores" con el filtro NVDA puesto y que aparezca en la raíz sin ticker sería tirar dos
/// decisiones que el usuario acababa de tomar.
Future<void> createNoteInLab(
  BuildContext context,
  WidgetRef ref, {
  NoteDraft? draft,
}) async {
  if (!await _confirmDiscardIfDirty(context, ref)) return;

  final filter = ref.read(labFilterProvider);
  ref.read(labEditorTargetProvider.notifier).state = LabEditorTarget.draft(
    draft ??
        NoteDraft.blank(
          folderId: filter.requestFolderId,
          ticker: filter.ticker,
        ),
  );
  if (!context.mounted) return;
  if (context.isMasterDetail) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const NoteEditorScreen()),
  );
}

/// Pregunta antes de reemplazar una nota con cambios sin guardar.
///
/// Devuelve `false` si el usuario decidió quedarse. Es el precio del guardado explícito: sin esta
/// confirmación, un clic en otra nota tiraría el texto sin decir nada.
Future<bool> _confirmDiscardIfDirty(BuildContext context, WidgetRef ref) async {
  if (!ref.read(labEditorDirtyProvider)) return true;

  final discard = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Cambios sin guardar'),
      content: const Text(
        'La nota que tenés abierta tiene cambios que no se guardaron. Si seguís, se pierden.',
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

  if (discard ?? false) {
    ref.read(labEditorDirtyProvider.notifier).state = false;
    return true;
  }
  return false;
}

/// El editor como pantalla completa, para los anchos donde no entra como tercera columna.
class NoteEditorScreen extends ConsumerWidget {
  const NoteEditorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(labEditorTargetProvider);

    return Scaffold(
      body: SafeArea(
        child: target == null
            // Puede pasar legítimamente: borrar desde el editor la nota que está abierta limpia el
            // target, y esta pantalla se queda un frame sin nada que mostrar antes de desapilarse.
            ? const _EditorPlaceholder()
            : NoteEditorPanel(target: target),
      ),
    );
  }
}

class _EditorPlaceholder extends StatelessWidget {
  const _EditorPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.edit_note_outlined, size: 46, color: AppTheme.textMuted),
            SizedBox(height: 14),
            Text(
              'Elegí una nota de la lista para leerla o editarla,\n'
              'o creá una nueva con el botón de nota.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textMuted, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}
