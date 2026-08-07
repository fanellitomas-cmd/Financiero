import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../data/folder.dart';
import '../data/note.dart';
import '../data/notes_repository.dart';

/// Estado del Investment Lab: el árbol de carpetas, el filtro activo del explorador y qué nota está
/// abierta en el editor.

/// El árbol completo del usuario.
///
/// Una sola consulta para todo el árbol y no una por nivel: son decenas de filas y el backend ya las
/// devuelve planas con `depth`/`path` calculados, así que ir por niveles serían N requests para
/// reconstruir algo que llega hecho en uno.
///
/// `autoDispose`: al volver a la pantalla se relee, así una carpeta creada desde otro dispositivo
/// aparece sin reiniciar la app.
final foldersProvider = FutureProvider.autoDispose<List<Folder>>(
  (ref) => ref.watch(foldersRepositoryProvider).list(),
);

/// Índice por id, para que el editor y el explorador resuelvan `folderId -> nombre/ruta` sin
/// recorrer la lista en cada fila.
final foldersByIdProvider = Provider.autoDispose<Map<String, Folder>>((ref) {
  final folders = ref.watch(foldersProvider).valueOrNull ?? const <Folder>[];
  return {for (final folder in folders) folder.id: folder};
});

/// Qué subconjunto de notas mira el explorador.
///
/// Son tres alcances y no dos porque "todas" y "las que no están en ninguna carpeta" son preguntas
/// distintas: sin `root`, las notas sueltas quedarían visibles solo dentro de "todas", mezcladas con
/// las archivadas, y no habría forma de encontrar lo que todavía no organizaste.
enum LabScope { all, root, folder }

@immutable
class LabFilter {
  const LabFilter({
    this.scope = LabScope.all,
    this.folderId,
    this.ticker,
    this.query,
  });

  final LabScope scope;

  /// Solo tiene sentido con `scope == LabScope.folder`. Se conserva igual al cambiar de alcance para
  /// poder volver a la carpeta anterior sin re-seleccionarla.
  final String? folderId;

  final String? ticker;
  final String? query;

  LabFilter copyWith({
    LabScope? scope,
    String? folderId,
    bool clearTicker = false,
    String? ticker,
    bool clearQuery = false,
    String? query,
  }) =>
      LabFilter(
        scope: scope ?? this.scope,
        folderId: folderId ?? this.folderId,
        ticker: clearTicker ? null : (ticker ?? this.ticker),
        query: clearQuery ? null : (query ?? this.query),
      );

  /// El `folder_id` que va al request: solo cuando el alcance es una carpeta concreta. Mandarlo con
  /// alcance "todas" filtraría por la última carpeta visitada, que no es lo que el usuario pidió.
  String? get requestFolderId => scope == LabScope.folder ? folderId : null;

  bool get rootOnly => scope == LabScope.root;

  bool get hasTextFilters =>
      (ticker?.isNotEmpty ?? false) || (query?.isNotEmpty ?? false);

  // `==`/`hashCode` a mano porque este objeto es la clave de un `family`: sin igualdad estructural,
  // cada rebuild construiría un filtro nuevo y distinto, y el provider volvería a pedir las notas al
  // servidor en cada frame.
  @override
  bool operator ==(Object other) =>
      other is LabFilter &&
      other.scope == scope &&
      other.folderId == folderId &&
      other.ticker == ticker &&
      other.query == query;

  @override
  int get hashCode => Object.hash(scope, folderId, ticker, query);
}

/// El filtro del explorador, con debounce sobre el texto.
///
/// La búsqueda es "en tiempo real" desde el punto de vista del usuario pero NO un request por
/// tecla: escribir "margen bruto" son doce pulsaciones y once de esos requests son consultas que
/// nadie hizo, cuyas respuestas además pueden llegar desordenadas.
class LabFilterController extends StateNotifier<LabFilter> {
  LabFilterController() : super(const LabFilter());

  static const _debounce = Duration(milliseconds: 300);

  Timer? _pending;

  @override
  void dispose() {
    _pending?.cancel();
    super.dispose();
  }

  void selectAll() => _setScope(const LabFilter().copyWith(
        scope: LabScope.all,
        ticker: state.ticker,
        query: state.query,
      ));

  void selectRoot() => _setScope(state.copyWith(scope: LabScope.root));

  void selectFolder(String folderId) =>
      _setScope(state.copyWith(scope: LabScope.folder, folderId: folderId));

  /// Si la carpeta seleccionada desaparece (la borraron), el alcance vuelve a "todas" en vez de
  /// quedar apuntando a un id inexistente — que devolvería una lista vacía indistinguible de una
  /// carpeta sin notas.
  void forgetFolder(String folderId) {
    if (state.folderId != folderId) return;
    state = LabFilter(
      scope: LabScope.all,
      ticker: state.ticker,
      query: state.query,
    );
  }

  void _setScope(LabFilter next) {
    _pending?.cancel();
    state = next;
  }

  void setQuery(String raw) {
    final trimmed = raw.trim();
    _pending?.cancel();
    _pending = Timer(_debounce, () {
      if (!mounted) return;
      state = trimmed.isEmpty
          ? state.copyWith(clearQuery: true)
          : state.copyWith(query: trimmed);
    });
  }

  void setTicker(String raw) {
    final trimmed = raw.trim().toUpperCase();
    _pending?.cancel();
    _pending = Timer(_debounce, () {
      if (!mounted) return;
      state = trimmed.isEmpty
          ? state.copyWith(clearTicker: true)
          : state.copyWith(ticker: trimmed);
    });
  }

  /// Limpia los filtros de texto pero conserva el alcance: quien buscó dentro de una carpeta y
  /// limpia la búsqueda espera seguir en esa carpeta, no volver a "todas".
  void clearTextFilters() {
    _pending?.cancel();
    state = state.copyWith(clearQuery: true, clearTicker: true);
  }
}

final labFilterProvider =
    StateNotifierProvider<LabFilterController, LabFilter>((ref) {
  return LabFilterController();
});

/// Las notas del filtro activo.
///
/// `family` sobre el filtro (en vez de leerlo adentro) para que Riverpod cachee por combinación: ir
/// a una carpeta y volver muestra la lista anterior al instante en vez de un spinner, y el
/// `autoDispose` la descarta cuando ya nadie la mira.
final notesProvider =
    FutureProvider.autoDispose.family<NotePage, LabFilter>((ref, filter) {
  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);
  return ref.watch(notesRepositoryProvider).list(
        folderId: filter.requestFolderId,
        rootOnly: filter.rootOnly,
        ticker: filter.ticker,
        query: filter.query,
        cancelToken: cancelToken,
      );
});

/// Las notas del explorador, con el filtro que está activo ahora.
final labNotesProvider = Provider.autoDispose<AsyncValue<NotePage>>((ref) {
  return ref.watch(notesProvider(ref.watch(labFilterProvider)));
});

/// Las notas de un ticker, para la pestaña "Notas" de la Ficha del activo.
///
/// Provider aparte y no el filtro del Lab: son dos vistas independientes que coexisten en pantalla
/// en escritorio, y compartir el filtro haría que abrir la Ficha de NVDA cambie lo que muestra el
/// explorador del Lab en la otra mitad de la ventana.
final tickerNotesProvider =
    FutureProvider.autoDispose.family<NotePage, String>((ref, ticker) {
  return ref.watch(notesRepositoryProvider).list(ticker: ticker, limit: 100);
});

/// El cuerpo completo de una nota. Se pide recién al abrirla — el listado no lo trae.
final noteDetailProvider =
    FutureProvider.autoDispose.family<Note, String>((ref, noteId) {
  return ref.watch(notesRepositoryProvider).get(noteId);
});

/// Qué hay abierto en el editor.
///
/// `null` = nada (el panel muestra su placeholder). Un id = una nota guardada. [LabEditorTarget.nuevo]
/// = un borrador que todavía no existe en el servidor.
@immutable
class LabEditorTarget {
  const LabEditorTarget._({this.noteId, this.draft});

  /// Una nota ya guardada.
  const LabEditorTarget.existing(String id) : this._(noteId: id);

  /// Una nota nueva, opcionalmente con contenido ya puesto (por ejemplo la síntesis de la Ficha de
  /// Inteligencia insertada desde el detalle del activo).
  const LabEditorTarget.draft(NoteDraft draft) : this._(draft: draft);

  final String? noteId;
  final NoteDraft? draft;

  bool get isNew => noteId == null;
}

final labEditorTargetProvider = StateProvider<LabEditorTarget?>((ref) => null);

/// ¿El editor tiene cambios sin guardar?
///
/// Vive fuera del editor porque quien necesita saberlo es el explorador: al hacer clic en otra nota
/// hay que avisar ANTES de reemplazar lo que está abierto. Con el flag dentro del `State` del editor,
/// el explorador no tendría forma de consultarlo y el trabajo se perdería en silencio.
final labEditorDirtyProvider = StateProvider<bool>((ref) => false);

/// Acciones de escritura del Lab.
///
/// Viven en un notifier y no en las pantallas porque cada mutación tiene que invalidar más de un
/// provider, y esa lista es fácil de olvidar en un call site: borrar una carpeta cambia el árbol Y
/// las notas visibles Y posiblemente el filtro activo. Repartir eso entre botones dejaría la
/// pantalla mostrando datos viejos según desde dónde se hizo la acción.
class LabActions {
  LabActions(this._ref);

  final Ref _ref;

  NotesRepository get _notes => _ref.read(notesRepositoryProvider);

  void _invalidateNotes() {
    // `invalidate` sobre el family entero: cambiar una nota puede afectar la lista de "todas", la de
    // su carpeta, la de la carpeta de la que salió y la del ticker al que estaba vinculada.
    _ref.invalidate(notesProvider);
    _ref.invalidate(tickerNotesProvider);
  }

  Future<Note> createNote(NoteDraft draft) async {
    final created = await _notes.create(draft);
    _invalidateNotes();
    // El árbol también: el `note_count` de la carpeta destino acaba de cambiar.
    _ref.invalidate(foldersProvider);
    return created;
  }

  Future<Note> saveNote(String noteId, NoteDraft draft) async {
    final saved = await _notes.save(noteId, draft);
    _invalidateNotes();
    _ref.invalidate(noteDetailProvider(noteId));
    _ref.invalidate(foldersProvider);
    return saved;
  }

  /// Fija/desfija sin abrir el editor. Manda SOLO `pinned`: un PATCH completo desde la lista
  /// tendría que traerse el cuerpo primero para no borrarlo.
  Future<void> togglePinned(String noteId, {required bool pinned}) async {
    await _notes.update(noteId, pinned: pinned);
    _invalidateNotes();
    _ref.invalidate(noteDetailProvider(noteId));
  }

  Future<void> moveNote(String noteId, {String? folderId}) async {
    await _notes.update(
      noteId,
      folderId: folderId == null
          ? const FieldUpdate<String>.clear()
          : FieldUpdate<String>.to(folderId),
    );
    _invalidateNotes();
    _ref.invalidate(noteDetailProvider(noteId));
    _ref.invalidate(foldersProvider);
  }

  Future<void> deleteNote(String noteId) async {
    await _notes.remove(noteId);
    // Si la nota borrada era la abierta, el editor se cierra: dejarlo mostrando el cuerpo de algo
    // que ya no existe invitaría a guardar y recibir un 404.
    final open = _ref.read(labEditorTargetProvider);
    if (open?.noteId == noteId) {
      _ref.read(labEditorTargetProvider.notifier).state = null;
    }
    _invalidateNotes();
    _ref.invalidate(foldersProvider);
  }

  Future<Folder> createFolder(String name, {String? parentId}) async {
    final created =
        await _ref.read(foldersRepositoryProvider).create(name, parentId: parentId);
    _ref.invalidate(foldersProvider);
    return created;
  }

  Future<Folder> renameFolder(String folderId, String name) async {
    final updated =
        await _ref.read(foldersRepositoryProvider).update(folderId, name: name);
    _ref.invalidate(foldersProvider);
    return updated;
  }

  Future<Folder> moveFolder(String folderId, {String? parentId}) async {
    final updated = await _ref.read(foldersRepositoryProvider).update(
          folderId,
          parentId: parentId == null
              ? const FieldUpdate<String>.clear()
              : FieldUpdate<String>.to(parentId),
        );
    _ref.invalidate(foldersProvider);
    return updated;
  }

  Future<FolderDeletionResult> deleteFolder(
    String folderId, {
    bool cascade = false,
  }) async {
    final result = await _ref
        .read(foldersRepositoryProvider)
        .remove(folderId, cascade: cascade);
    _ref.read(labFilterProvider.notifier).forgetFolder(folderId);
    _ref.invalidate(foldersProvider);
    _invalidateNotes();
    return result;
  }
}

final labActionsProvider = Provider<LabActions>((ref) => LabActions(ref));
