import 'package:dio/dio.dart';
import 'package:financiero_app/core/providers.dart';
import 'package:financiero_app/core/theme/app_theme.dart';
import 'package:financiero_app/features/lab/data/folder.dart';
import 'package:financiero_app/features/lab/data/folders_repository.dart';
import 'package:financiero_app/features/lab/data/note.dart';
import 'package:financiero_app/features/lab/data/note_formatting.dart';
import 'package:financiero_app/features/lab/data/notes_repository.dart';
import 'package:financiero_app/features/lab/presentation/investment_lab_screen.dart';
import 'package:financiero_app/features/lab/presentation/lab_controller.dart';
import 'package:financiero_app/features/lab/widgets/folder_dialogs.dart';
import 'package:financiero_app/features/lab/widgets/markdown_view.dart';
import 'package:financiero_app/features/lab/widgets/note_explorer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests del Investment Lab: modelos, filtros, visor de Markdown y las tres piezas de la UI
/// (sidebar de carpetas, explorador de notas y editor).
///
/// Los contratos que este módulo promete y que son fáciles de romper sin darse cuenta:
///
///   1. **Omitir un campo y mandarlo en `null` significan cosas distintas.** Es lo que permite sacar
///      una nota de su carpeta; si el payload colapsa las dos intenciones, desarchivar deja de
///      funcionar y el bug es invisible (el request devuelve 200).
///   2. **El listado NO trae el cuerpo.** La UI muestra `excerpt` y `content_length`; si empezara a
///      leer `content` de un resumen mostraría vacío en notas que sí tienen texto.
///   3. **Borrar una carpeta no borra notas**, y el resumen del backend hay que decirlo: sin el
///      SnackBar, el usuario asume que perdió todo.
///   4. **Guardado explícito con aviso.** El editor no autoguarda, así que "sin guardar" tiene que
///      ser visible y hay que avisar antes de descartar.
///
/// Los dobles son los repositorios (con `implements`, para no arrastrar el `ApiClient` del
/// constructor), así se ejercita también el controller, que es quien decide qué invalidar.

// --- Dobles ------------------------------------------------------------------------------------

class _FakeFoldersRepository implements FoldersRepository {
  _FakeFoldersRepository({List<Folder> folders = const []})
      : _folders = List.of(folders);

  List<Folder> _folders;

  int listCalls = 0;
  final List<(String, String?)> created = [];
  final List<(String, String?)> renamed = [];
  final List<(String, String?)> moved = [];
  final List<(String, bool)> removed = [];

  FolderDeletionResult deletionResult = const FolderDeletionResult(
    deletedFolderId: 'f1',
    cascade: false,
    reparentedFolders: 0,
    detachedNotes: 0,
    deletedFolders: 0,
    deletedNotes: 0,
  );

  Object? failure;

  void replace(List<Folder> folders) => _folders = List.of(folders);

  @override
  Future<List<Folder>> list() async {
    listCalls++;
    return _folders;
  }

  @override
  Future<Folder> create(String name, {String? parentId}) async {
    if (failure != null) throw failure!;
    created.add((name, parentId));
    return _folder(id: 'nueva', name: name, parentId: parentId);
  }

  @override
  Future<Folder> update(
    String folderId, {
    String? name,
    FieldUpdate<String>? parentId,
  }) async {
    if (failure != null) throw failure!;
    if (name != null) renamed.add((folderId, name));
    if (parentId != null) moved.add((folderId, parentId.value));
    return _folder(id: folderId, name: name ?? 'x', parentId: parentId?.value);
  }

  @override
  Future<FolderDeletionResult> remove(
    String folderId, {
    bool cascade = false,
  }) async {
    if (failure != null) throw failure!;
    removed.add((folderId, cascade));
    return deletionResult;
  }
}

class _FakeNotesRepository implements NotesRepository {
  _FakeNotesRepository({this.page = NotePage.empty, this.note});

  NotePage page;
  Note? note;
  Object? failure;

  final List<Map<String, Object?>> listQueries = [];
  final List<NoteDraft> createdDrafts = [];
  final List<(String, NoteDraft)> savedDrafts = [];
  final List<Map<String, dynamic>> patches = [];
  final List<String> removedIds = [];

  @override
  Future<NotePage> list({
    String? folderId,
    bool rootOnly = false,
    String? ticker,
    String? query,
    int limit = 50,
    int offset = 0,
    CancelToken? cancelToken,
  }) async {
    listQueries.add({
      'folderId': folderId,
      'rootOnly': rootOnly,
      'ticker': ticker,
      'query': query,
    });
    return page;
  }

  @override
  Future<Note> get(String noteId) async {
    if (failure != null) throw failure!;
    return note ?? _note(id: noteId);
  }

  @override
  Future<Note> create(NoteDraft draft) async {
    if (failure != null) throw failure!;
    createdDrafts.add(draft);
    return _note(
      id: 'creada',
      title: draft.effectiveTitle,
      content: draft.content,
      folderId: draft.folderId,
      ticker: draft.normalizedTicker,
      pinned: draft.pinned,
    );
  }

  @override
  Future<Note> update(
    String noteId, {
    String? title,
    String? content,
    bool? pinned,
    FieldUpdate<String>? folderId,
    FieldUpdate<String>? ticker,
  }) async {
    if (failure != null) throw failure!;
    patches.add(
      noteUpdatePayload(
        title: title,
        content: content,
        pinned: pinned,
        folderId: folderId,
        ticker: ticker,
      ),
    );
    return note ?? _note(id: noteId);
  }

  @override
  Future<Note> save(String noteId, NoteDraft draft) async {
    if (failure != null) throw failure!;
    savedDrafts.add((noteId, draft));
    return _note(
      id: noteId,
      title: draft.effectiveTitle,
      content: draft.content,
      folderId: draft.folderId,
      ticker: draft.normalizedTicker,
      pinned: draft.pinned,
    );
  }

  @override
  Future<void> remove(String noteId) async {
    if (failure != null) throw failure!;
    removedIds.add(noteId);
  }
}

// --- Fixtures ----------------------------------------------------------------------------------

Folder _folder({
  required String id,
  required String name,
  String? parentId,
  int depth = 0,
  String? path,
  int noteCount = 0,
  int subfolderCount = 0,
}) =>
    Folder(
      id: id,
      name: name,
      parentId: parentId,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      depth: depth,
      path: path ?? name,
      noteCount: noteCount,
      subfolderCount: subfolderCount,
    );

Note _note({
  required String id,
  String title = 'Tesis',
  String content = 'Cuerpo de la tesis.',
  String? folderId,
  String? ticker,
  bool pinned = false,
}) =>
    Note(
      id: id,
      folderId: folderId,
      ticker: ticker,
      title: title,
      content: content,
      pinned: pinned,
      createdAt: DateTime.utc(2026, 8, 1, 10),
      updatedAt: DateTime.utc(2026, 8, 5, 10),
    );

NoteSummary _summary({
  required String id,
  String title = 'Tesis NVDA',
  String excerpt = 'El data center sigue traccionando.',
  int contentLength = 240,
  String? ticker,
  String? folderId,
  bool pinned = false,
}) =>
    NoteSummary(
      id: id,
      folderId: folderId,
      ticker: ticker,
      title: title,
      pinned: pinned,
      createdAt: DateTime.utc(2026, 8, 1, 10),
      updatedAt: DateTime.utc(2026, 8, 5, 10),
      excerpt: excerpt,
      contentLength: contentLength,
    );

/// Árbol de tres carpetas: Research (con Semis dentro) y Trades.
final _tree = [
  _folder(id: 'research', name: 'Research', subfolderCount: 1, noteCount: 2),
  _folder(
    id: 'semis',
    name: 'Semis',
    parentId: 'research',
    depth: 1,
    path: 'Research / Semis',
    noteCount: 5,
  ),
  _folder(id: 'trades', name: 'Trades'),
];

Future<void> _pumpLab(
  WidgetTester tester, {
  required _FakeFoldersRepository folders,
  required _FakeNotesRepository notes,
  Size size = const Size(1500, 1200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        foldersRepositoryProvider.overrideWithValue(folders),
        notesRepositoryProvider.overrideWithValue(notes),
      ],
      child: MaterialApp(
        theme: AppTheme.dark,
        home: const InvestmentLabScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // --- Modelos --------------------------------------------------------------------------------

  group('Folder', () {
    test('parsea los campos que el backend calcula', () {
      final folder = Folder.fromJson(const {
        'id': 'f1',
        'name': 'Semis',
        'parent_id': 'research',
        'created_at': '2026-08-01T10:00:00Z',
        'updated_at': '2026-08-05T10:00:00Z',
        'depth': 1,
        'path': 'Research / Semis',
        'note_count': 5,
        'subfolder_count': 2,
      });

      expect(folder.depth, 1);
      expect(folder.path, 'Research / Semis');
      expect(folder.noteCount, 5);
      expect(folder.subfolderCount, 2);
      expect(folder.isRoot, isFalse);
    });

    test('sin los campos calculados degrada en vez de romper', () {
      // El cliente no reconstruye la jerarquía, así que si el backend dejara de mandar `depth`/`path`
      // lo que corresponde es dibujar la carpeta al nivel de la raíz — no crashear la pantalla.
      final folder = Folder.fromJson(const {
        'id': 'f1',
        'name': 'Suelta',
        'parent_id': null,
        'created_at': '2026-08-01T10:00:00Z',
        'updated_at': '2026-08-01T10:00:00Z',
      });

      expect(folder.depth, 0);
      expect(folder.path, 'Suelta');
      expect(folder.isRoot, isTrue);
    });
  });

  group('FolderDeletionResult.describe', () {
    test('el borrado seguro nombra lo que sobrevivió', () {
      const result = FolderDeletionResult(
        deletedFolderId: 'f1',
        cascade: false,
        reparentedFolders: 2,
        detachedNotes: 1,
        deletedFolders: 0,
        deletedNotes: 0,
      );

      final message = result.describe('Research');

      expect(message, contains('Se eliminó «Research»'));
      expect(message, contains('2 subcarpetas subieron un nivel'));
      expect(message, contains('1 nota volvió a la raíz'));
    });

    test('singular y plural se conjugan', () {
      const result = FolderDeletionResult(
        deletedFolderId: 'f1',
        cascade: false,
        reparentedFolders: 1,
        detachedNotes: 3,
        deletedFolders: 0,
        deletedNotes: 0,
      );

      expect(result.describe('X'), contains('1 subcarpeta subió un nivel'));
      expect(result.describe('X'), contains('3 notas volvieron a la raíz'));
    });

    test('la cascada nombra lo que se destruyó', () {
      const result = FolderDeletionResult(
        deletedFolderId: 'f1',
        cascade: true,
        reparentedFolders: 0,
        detachedNotes: 0,
        deletedFolders: 2,
        deletedNotes: 7,
      );

      final message = result.describe('Research');

      expect(message, contains('junto con'));
      expect(message, contains('2 subcarpetas'));
      expect(message, contains('7 notas'));
    });

    test('una carpeta vacía lo dice y no enumera ceros', () {
      const result = FolderDeletionResult(
        deletedFolderId: 'f1',
        cascade: false,
        reparentedFolders: 0,
        detachedNotes: 0,
        deletedFolders: 0,
        deletedNotes: 0,
      );

      expect(result.describe('Vacía'), 'Se eliminó «Vacía» (estaba vacía).');
    });
  });

  group('NoteSummary y NotePage', () {
    test('el resumen trae excerpt y largo, no el cuerpo', () {
      final summary = NoteSummary.fromJson(const {
        'id': 'n1',
        'folder_id': null,
        'ticker': 'NVDA',
        'title': 'Tesis',
        'pinned': true,
        'created_at': '2026-08-01T10:00:00Z',
        'updated_at': '2026-08-05T10:00:00Z',
        'excerpt': 'Primera línea…',
        'content_length': 4200,
      });

      expect(summary.excerpt, 'Primera línea…');
      expect(summary.contentLength, 4200);
      expect(summary.isEmpty, isFalse);
      expect(summary.pinned, isTrue);
    });

    test('hasMore avisa que la página está truncada', () {
      final page = NotePage(
        items: [for (var index = 0; index < 50; index++) _summary(id: 'n$index')],
        total: 180,
        limit: 50,
        offset: 0,
      );

      expect(page.hasMore, isTrue);
      expect(
        NotePage(items: [_summary(id: 'n1')], total: 1, limit: 50, offset: 0)
            .hasMore,
        isFalse,
      );
    });
  });

  group('NoteDraft', () {
    test('un título vacío se guarda con un default en vez de un 422', () {
      expect(NoteDraft.blank().effectiveTitle, 'Nota sin título');
      expect(NoteDraft.blank(title: '   ').effectiveTitle, 'Nota sin título');
      expect(NoteDraft.blank(title: ' Tesis ').effectiveTitle, 'Tesis');
    });

    test('el ticker se normaliza a mayúsculas y el vacío queda en null', () {
      expect(NoteDraft.blank(ticker: 'nvda').normalizedTicker, 'NVDA');
      expect(NoteDraft.blank(ticker: '  ').normalizedTicker, isNull);
      expect(NoteDraft.blank().normalizedTicker, isNull);
    });

    test('differsFrom no marca sucio un borrador idéntico al servidor', () {
      final note = _note(id: 'n1', ticker: 'NVDA', folderId: 'research');
      expect(NoteDraft.fromNote(note).differsFrom(note), isFalse);
    });

    test('differsFrom detecta cada campo por separado', () {
      final note = _note(id: 'n1', ticker: 'NVDA', folderId: 'research');
      final base = NoteDraft.fromNote(note);

      expect(base.copyWith(title: 'Otro').differsFrom(note), isTrue);
      expect(base.copyWith(content: 'Otro cuerpo').differsFrom(note), isTrue);
      expect(base.copyWith(pinned: true).differsFrom(note), isTrue);
      expect(base.copyWith(clearFolder: true).differsFrom(note), isTrue);
      expect(base.copyWith(clearTicker: true).differsFrom(note), isTrue);
    });

    test('escribir y borrar vuelve a dejar el borrador limpio', () {
      // El flag de "sin guardar" se calcula comparando contra el servidor, no prendiéndose al
      // primer tecleo: si no, cualquier tipeo dejaría la nota marcada como sucia para siempre.
      final note = _note(id: 'n1', content: 'original');
      final dirty = NoteDraft.fromNote(note).copyWith(content: 'original!');
      expect(dirty.differsFrom(note), isTrue);
      expect(dirty.copyWith(content: 'original').differsFrom(note), isFalse);
    });

    test('toCreateJson omite la carpeta y el ticker vacíos', () {
      final json = NoteDraft.blank(title: 'Suelta').toCreateJson();

      expect(json['title'], 'Suelta');
      expect(json.containsKey('folder_id'), isFalse);
      expect(json.containsKey('ticker'), isFalse);
    });

    test('toCreateJson manda el ticker ya normalizado', () {
      final json = NoteDraft.blank(title: 'T', ticker: 'nvda').toCreateJson();
      expect(json['ticker'], 'NVDA');
    });
  });

  group('payload de PATCH — omitido vs null explícito', () {
    test('un campo omitido no viaja', () {
      final payload = noteUpdatePayload(pinned: true);

      expect(payload, {'pinned': true});
      // Que `folder_id` NO esté es lo que el backend lee como "dejala donde está". Si apareciera en
      // null, fijar una nota desde la lista la sacaría de su carpeta.
      expect(payload.containsKey('folder_id'), isFalse);
      expect(payload.containsKey('ticker'), isFalse);
    });

    test('FieldUpdate.clear() manda null explícito', () {
      final payload = noteUpdatePayload(
        folderId: const FieldUpdate<String>.clear(),
        ticker: const FieldUpdate<String>.clear(),
      );

      expect(payload.containsKey('folder_id'), isTrue);
      expect(payload['folder_id'], isNull);
      expect(payload.containsKey('ticker'), isTrue);
      expect(payload['ticker'], isNull);
    });

    test('FieldUpdate.to() manda el valor', () {
      final payload = noteUpdatePayload(folderId: const FieldUpdate.to('research'));
      expect(payload['folder_id'], 'research');
    });

    test('la misma regla vale para mover una carpeta a la raíz', () {
      expect(folderUpdatePayload(name: 'X'), {'name': 'X'});
      final toRoot = folderUpdatePayload(parentId: const FieldUpdate<String>.clear());
      expect(toRoot.containsKey('parent_id'), isTrue);
      expect(toRoot['parent_id'], isNull);
    });
  });

  // --- Filtros --------------------------------------------------------------------------------

  group('LabFilter', () {
    test('la igualdad es estructural para que el family no repida', () {
      // Sin esto, cada rebuild construiría una clave distinta y el provider pediría las notas al
      // servidor en cada frame.
      expect(
        const LabFilter(scope: LabScope.folder, folderId: 'a', query: 'x'),
        const LabFilter(scope: LabScope.folder, folderId: 'a', query: 'x'),
      );
      expect(
        const LabFilter(scope: LabScope.folder, folderId: 'a').hashCode,
        const LabFilter(scope: LabScope.folder, folderId: 'a').hashCode,
      );
      expect(
        const LabFilter(scope: LabScope.all),
        isNot(const LabFilter(scope: LabScope.root)),
      );
    });

    test('el folderId solo viaja cuando el alcance es una carpeta', () {
      // Conserva el id al cambiar de alcance (para poder volver), pero no lo manda: filtrar "todas"
      // por la última carpeta visitada devolvería algo que nadie pidió.
      const inFolder = LabFilter(scope: LabScope.folder, folderId: 'research');
      expect(inFolder.requestFolderId, 'research');

      const inAll = LabFilter(scope: LabScope.all, folderId: 'research');
      expect(inAll.requestFolderId, isNull);
      expect(inAll.rootOnly, isFalse);

      const inRoot = LabFilter(scope: LabScope.root, folderId: 'research');
      expect(inRoot.requestFolderId, isNull);
      expect(inRoot.rootOnly, isTrue);
    });

    test('hasTextFilters distingue filtros activos de vacíos', () {
      expect(const LabFilter().hasTextFilters, isFalse);
      expect(const LabFilter(query: 'margen').hasTextFilters, isTrue);
      expect(const LabFilter(ticker: 'NVDA').hasTextFilters, isTrue);
    });
  });

  group('LabFilterController', () {
    test('la búsqueda se aplica una vez, después del debounce', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(labFilterProvider.notifier);

      controller.setQuery('m');
      controller.setQuery('ma');
      controller.setQuery('margen');
      // Todavía nada: cada tecla canceló el timer anterior, así que no hubo tres consultas.
      expect(container.read(labFilterProvider).query, isNull);

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(container.read(labFilterProvider).query, 'margen');
    });

    test('el ticker se normaliza a mayúsculas y vaciarlo lo limpia', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(labFilterProvider.notifier);

      controller.setTicker('nvda');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(container.read(labFilterProvider).ticker, 'NVDA');

      controller.setTicker('  ');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(container.read(labFilterProvider).ticker, isNull);
    });

    test('limpiar los filtros de texto conserva la carpeta elegida', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(labFilterProvider.notifier);

      controller.selectFolder('research');
      controller.clearTextFilters();

      final filter = container.read(labFilterProvider);
      expect(filter.scope, LabScope.folder);
      expect(filter.folderId, 'research');
    });

    test('forgetFolder solo resetea si la carpeta borrada era la activa', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(labFilterProvider.notifier);

      controller.selectFolder('research');
      controller.forgetFolder('otra');
      expect(container.read(labFilterProvider).scope, LabScope.folder);

      controller.forgetFolder('research');
      // Vuelve a "todas" en vez de quedar apuntando a un id inexistente, que devolvería una lista
      // vacía indistinguible de una carpeta sin notas.
      expect(container.read(labFilterProvider).scope, LabScope.all);
    });
  });

  group('selectableFolders', () {
    test('excluye el subárbol completo, no solo la carpeta movida', () {
      // Mover "Research" dentro de "Research / Semis" también cerraría un ciclo, aunque el destino
      // sea otra fila de la lista.
      final options = selectableFolders(_tree, excludeSubtreeOf: 'research');

      expect(options.map((folder) => folder.id), ['trades']);
    });

    test('una hermana con el nombre parecido NO se excluye', () {
      // El descarte va por `parentId` en cascada y no por el prefijo de `path`: "NVDA" y "NVDA
      // histórico" comparten prefijo sin ser parientes.
      final folders = [
        _folder(id: 'nvda', name: 'NVDA'),
        _folder(id: 'nvda-hist', name: 'NVDA histórico'),
      ];

      final options = selectableFolders(folders, excludeSubtreeOf: 'nvda');

      expect(options.map((folder) => folder.id), ['nvda-hist']);
    });

    test('sin exclusión devuelve todo', () {
      expect(selectableFolders(_tree).length, 3);
    });
  });

  // --- Formateo -------------------------------------------------------------------------------

  group('formatRelativeTime', () {
    final now = DateTime.utc(2026, 8, 6, 12);

    test('usa unidades relativas hasta la semana', () {
      expect(formatRelativeTime(now, now: now), 'recién');
      expect(
        formatRelativeTime(now.subtract(const Duration(minutes: 5)), now: now),
        'hace 5 min',
      );
      expect(
        formatRelativeTime(now.subtract(const Duration(hours: 3)), now: now),
        'hace 3 h',
      );
      expect(
        formatRelativeTime(now.subtract(const Duration(days: 4)), now: now),
        'hace 4 d',
      );
    });

    test('a partir de una semana muestra la fecha', () {
      // "hace 23 d" obliga a calcular; la fecha ya dice más.
      expect(
        formatRelativeTime(DateTime.utc(2026, 7, 1), now: now),
        contains('2026'),
      );
    });

    test('un timestamp futuro no dice "hace -3 min"', () {
      expect(
        formatRelativeTime(now.add(const Duration(minutes: 3)), now: now),
        'recién',
      );
    });
  });

  group('formatContentLength', () {
    test('distingue una nota vacía de una larga', () {
      expect(formatContentLength(0), 'vacía');
      expect(formatContentLength(240), '240 car.');
      expect(formatContentLength(4200), '4,2 mil car.');
    });
  });

  // --- Visor de Markdown ----------------------------------------------------------------------

  group('parseMarkdownBlocks', () {
    test('reconoce títulos, viñetas, listas numeradas, citas y separadores', () {
      final blocks = parseMarkdownBlocks('''
# Tesis NVDA
## Fundamentales
### Detalle
- Margen alto
* Otra viñeta
1. Primero
7. Séptimo
> Una cita
---
''');

      expect(
        blocks.map((block) => block.kind),
        [
          MarkdownBlockKind.heading1,
          MarkdownBlockKind.heading2,
          MarkdownBlockKind.heading3,
          MarkdownBlockKind.bullet,
          MarkdownBlockKind.bullet,
          MarkdownBlockKind.ordered,
          MarkdownBlockKind.ordered,
          MarkdownBlockKind.quote,
          MarkdownBlockKind.rule,
        ],
      );
      // El ordinal es el que escribió el usuario, no una renumeración: si puso "7." es porque quiso.
      expect(blocks[6].ordinal, 7);
      expect(blocks[0].text, 'Tesis NVDA');
      expect(blocks[7].text, 'Una cita');
    });

    test('las líneas sueltas de un párrafo se unen', () {
      // Un salto simple en Markdown es continuación, no párrafo nuevo. Sin esto, un texto escrito
      // con márgenes angostos se vería como renglones sueltos.
      final blocks = parseMarkdownBlocks('Primera línea\nsegunda línea\n\nOtro párrafo');

      expect(blocks.length, 2);
      expect(blocks[0].text, 'Primera línea segunda línea');
      expect(blocks[1].text, 'Otro párrafo');
    });

    test('las citas consecutivas forman un solo bloque', () {
      final blocks = parseMarkdownBlocks('> línea uno\n> línea dos');

      expect(blocks.length, 1);
      expect(blocks.single.kind, MarkdownBlockKind.quote);
      expect(blocks.single.text, 'línea uno línea dos');
    });

    test('un bloque de código conserva los saltos y no se re-parsea', () {
      final blocks = parseMarkdownBlocks('```\nP/E = 40\n- no es viñeta\n```');

      expect(blocks.single.kind, MarkdownBlockKind.code);
      expect(blocks.single.text, 'P/E = 40\n- no es viñeta');
    });

    test('una cerca sin cerrar no se come el resto de la nota', () {
      // Se prefiere mostrar el resto como código antes que abortar: el texto es del usuario.
      final blocks = parseMarkdownBlocks('```\nalgo\nmás');

      expect(blocks.single.kind, MarkdownBlockKind.code);
      expect(blocks.single.text, 'algo\nmás');
    });

    test('un texto vacío no produce bloques', () {
      expect(parseMarkdownBlocks(''), isEmpty);
      expect(parseMarkdownBlocks('\n\n  \n'), isEmpty);
    });
  });

  group('parseInlineMarkdown', () {
    test('resuelve negrita, itálica y código', () {
      expect(
        parseInlineMarkdown('El **margen** es *alto* y el `P/E` bajo'),
        const [
          MarkdownSpan('El '),
          MarkdownSpan('margen', bold: true),
          MarkdownSpan(' es '),
          MarkdownSpan('alto', italic: true),
          MarkdownSpan(' y el '),
          MarkdownSpan('P/E', code: true),
          MarkdownSpan(' bajo'),
        ],
      );
    });

    test('la doble marca gana sobre la simple', () {
      // Si se probara `*` antes que `**`, "**texto**" abriría una itálica con un asterisco adentro.
      expect(
        parseInlineMarkdown('**negrita**'),
        const [MarkdownSpan('negrita', bold: true)],
      );
    });

    test('una multiplicación no abre una itálica', () {
      // El caso que aparece de verdad en una nota financiera: "3 * 4" o una viñeta mal escrita.
      expect(
        parseInlineMarkdown('El total es 3 * 4 * 5'),
        const [MarkdownSpan('El total es 3 * 4 * 5')],
      );
    });

    test('un guion bajo dentro de una palabra no marca nada', () {
      // `free_cash_flow` es el nombre de una métrica, no una itálica.
      expect(
        parseInlineMarkdown('el ratio free_cash_flow_yield sube'),
        const [MarkdownSpan('el ratio free_cash_flow_yield sube')],
      );
    });

    test('un marcador sin cerrar queda como texto literal', () {
      expect(
        parseInlineMarkdown('costo * unidad'),
        const [MarkdownSpan('costo * unidad')],
      );
      expect(
        parseInlineMarkdown('sin cerrar `codigo'),
        const [MarkdownSpan('sin cerrar `codigo')],
      );
    });

    test('el código inline no interpreta lo de adentro', () {
      expect(
        parseInlineMarkdown('usá `a*b*c` así'),
        const [
          MarkdownSpan('usá '),
          MarkdownSpan('a*b*c', code: true),
          MarkdownSpan(' así'),
        ],
      );
    });

    test('negrita e itálica se combinan anidadas', () {
      expect(
        parseInlineMarkdown('**muy _importante_**'),
        const [
          MarkdownSpan('muy ', bold: true),
          MarkdownSpan('importante', bold: true, italic: true),
        ],
      );
    });

    test('la forma *** no se interpreta, pero no pierde texto', () {
      // Límite conocido del subconjunto: resolver `***` requiere el manejo de "delimiter runs" de
      // CommonMark, que es la mitad de su especificación de énfasis. Se degrada dejando el asterisco
      // sobrante como texto — nunca comiéndose un carácter que el usuario escribió.
      final spans = parseInlineMarkdown('**muy *importante***');

      expect(spans.map((span) => span.text).join(), 'muy *importante*');
      expect(spans.first.bold, isTrue);
    });
  });

  group('MarkdownView', () {
    testWidgets('renderiza el texto con Text.rich y no con RichText crudo',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: MarkdownView(source: '# Título\n\nEl **margen** es alto.'),
          ),
        ),
      );

      expect(find.text('Título', findRichText: true), findsOneWidget);
      expect(find.text('El margen es alto.', findRichText: true), findsOneWidget);

      // El bloque se arma con `Text.rich` y NUNCA con `RichText` crudo, porque `RichText` no hereda
      // el `DefaultTextStyle` del tema: caería en la familia por defecto de Flutter ("Roboto"), que
      // no está bundleada, y en Web el texto quedaría INVISIBLE sin ningún error a la vista. Se
      // verifica sobre el render: cada párrafo tiene que llegar con una familia resuelta.
      final paragraphs =
          tester.renderObjectList<RenderParagraph>(find.byType(RichText));
      expect(paragraphs, isNotEmpty);
      for (final paragraph in paragraphs) {
        expect(paragraph.text.style?.fontFamily, 'AppSans');
      }
    });

    testWidgets('una nota vacía lo dice en vez de quedar en blanco',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: MarkdownView(source: '   ')),
        ),
      );

      expect(find.textContaining('todavía no tiene contenido'), findsOneWidget);
    });
  });

  // --- Sidebar de carpetas --------------------------------------------------------------------

  group('FolderTreeSidebar', () {
    testWidgets('dibuja los dos alcances y el árbol indentado por depth',
        (tester) async {
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(folders: _tree),
        notes: _FakeNotesRepository(),
      );

      // El texto del alcance aparece DOS veces a propósito (la fila del sidebar y el encabezado del
      // explorador), así que el finder se ancla al `ListTile` para hablar del sidebar.
      expect(find.widgetWithText(ListTile, 'Todas las notas'), findsOneWidget);
      // "Sin carpeta" es un alcance propio porque no se puede expresar eligiendo una carpeta.
      expect(find.widgetWithText(ListTile, 'Sin carpeta'), findsOneWidget);
      expect(find.text('Research'), findsOneWidget);
      expect(find.text('Semis'), findsOneWidget);

      ListTile tileFor(String name) => tester.widget<ListTile>(
            find.ancestor(of: find.text(name), matching: find.byType(ListTile)),
          );

      final research = tileFor('Research').contentPadding! as EdgeInsets;
      final semis = tileFor('Semis').contentPadding! as EdgeInsets;
      // La indentación es lo ÚNICO que comunica la jerarquía en una lista plana.
      expect(semis.left, greaterThan(research.left));
    });

    testWidgets('muestra el conteo de notas de cada carpeta', (tester) async {
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(folders: _tree),
        notes: _FakeNotesRepository(),
      );

      // 2 en Research y 5 en Semis, que son sus notas DIRECTAS (no un total recursivo).
      expect(find.text('2'), findsWidgets);
      expect(find.text('5'), findsOneWidget);
    });

    testWidgets('elegir una carpeta filtra las notas por ella', (tester) async {
      final notes = _FakeNotesRepository();
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(folders: _tree),
        notes: notes,
      );

      await tester.tap(find.text('Semis'));
      await tester.pumpAndSettle();

      expect(notes.listQueries.last['folderId'], 'semis');
      expect(find.text('Research / Semis'), findsOneWidget);
    });

    testWidgets('"Sin carpeta" pide root_only y no un folder_id', (tester) async {
      final notes = _FakeNotesRepository();
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(folders: _tree),
        notes: notes,
      );

      await tester.tap(find.text('Sin carpeta'));
      await tester.pumpAndSettle();

      expect(notes.listQueries.last['rootOnly'], isTrue);
      expect(notes.listQueries.last['folderId'], isNull);
    });

    testWidgets('sin carpetas explica dónde viven las notas', (tester) async {
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(),
        notes: _FakeNotesRepository(),
      );

      expect(find.textContaining('Todavía no creaste carpetas'), findsOneWidget);
    });
  });

  group('borrado de carpeta', () {
    testWidgets('el diálogo ofrece la cascada solo como opción explícita',
        (tester) async {
      final folders = _FakeFoldersRepository(folders: _tree);
      await _pumpLab(tester, folders: folders, notes: _FakeNotesRepository());

      await tester.tap(find.byTooltip('Opciones de Research'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Eliminar').last);
      await tester.pumpAndSettle();

      // El default no pierde nada y lo dice; la cascada hay que tildarla.
      expect(find.textContaining('Nada se pierde'), findsOneWidget);
      expect(find.text('Contiene 2 notas y 1 subcarpeta.'), findsOneWidget);
      expect(find.byType(Checkbox), findsOneWidget);
      expect(find.text('Eliminar'), findsOneWidget);

      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      // Al tildar cambia el mensaje Y el botón: la acción destructiva no se disfraza.
      expect(find.textContaining('No se puede deshacer'), findsOneWidget);
      expect(find.text('Borrar todo'), findsOneWidget);
    });

    testWidgets('el resumen del backend se muestra en un SnackBar',
        (tester) async {
      final folders = _FakeFoldersRepository(folders: _tree)
        ..deletionResult = const FolderDeletionResult(
          deletedFolderId: 'research',
          cascade: false,
          reparentedFolders: 1,
          detachedNotes: 2,
          deletedFolders: 0,
          deletedNotes: 0,
        );
      await _pumpLab(tester, folders: folders, notes: _FakeNotesRepository());

      await tester.tap(find.byTooltip('Opciones de Research'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Eliminar').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Eliminar'));
      await tester.pumpAndSettle();

      expect(folders.removed, [('research', false)]);
      // Sin este aviso el usuario asume que sus notas se fueron con la carpeta.
      expect(
        find.textContaining('1 subcarpeta subió un nivel y 2 notas volvieron'),
        findsOneWidget,
      );
    });

    testWidgets('un error del backend se muestra sin romper la pantalla',
        (tester) async {
      final folders = _FakeFoldersRepository(folders: _tree)
        ..failure = DioException(
          requestOptions: RequestOptions(path: '/folders/research'),
          response: Response(
            requestOptions: RequestOptions(path: '/folders/research'),
            statusCode: 404,
            data: {'detail': 'Carpeta no encontrada.'},
          ),
        );
      await _pumpLab(tester, folders: folders, notes: _FakeNotesRepository());

      await tester.tap(find.byTooltip('Opciones de Research'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Eliminar').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Eliminar'));
      await tester.pumpAndSettle();

      expect(find.text('Carpeta no encontrada.'), findsOneWidget);
    });
  });

  // --- Explorador de notas --------------------------------------------------------------------

  group('NoteExplorer', () {
    testWidgets('la lista muestra excerpt, ticker y metadatos', (tester) async {
      final notes = _FakeNotesRepository(
        page: NotePage(
          items: [
            _summary(
              id: 'n1',
              title: 'Tesis NVDA',
              excerpt: 'El data center sigue traccionando.',
              ticker: 'NVDA',
              contentLength: 4200,
              pinned: true,
            ),
          ],
          total: 1,
          limit: 50,
          offset: 0,
        ),
      );
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(folders: _tree),
        notes: notes,
      );

      expect(find.text('Tesis NVDA'), findsOneWidget);
      expect(find.text('El data center sigue traccionando.'), findsOneWidget);
      expect(find.byType(TickerBadge), findsWidgets);
      expect(find.textContaining('4,2 mil car.'), findsOneWidget);
      // Sin carpeta se dice explícitamente: el hueco sería indistinguible de un nombre no resuelto.
      expect(find.textContaining('Sin carpeta'), findsWidgets);
      expect(find.byIcon(Icons.push_pin), findsWidgets);
    });

    testWidgets('una nota sin cuerpo lo dice en vez de mostrar una fila muda',
        (tester) async {
      final notes = _FakeNotesRepository(
        page: NotePage(
          items: [_summary(id: 'n1', excerpt: '', contentLength: 0)],
          total: 1,
          limit: 50,
          offset: 0,
        ),
      );
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(),
        notes: notes,
      );

      expect(find.text('Sin contenido'), findsOneWidget);
      expect(find.textContaining('vacía'), findsOneWidget);
    });

    testWidgets('el toggle pasa de lista a grilla', (tester) async {
      final notes = _FakeNotesRepository(
        page: NotePage(
          items: [_summary(id: 'n1'), _summary(id: 'n2', title: 'Otra')],
          total: 2,
          limit: 50,
          offset: 0,
        ),
      );
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(),
        notes: notes,
      );

      expect(find.byType(ListView), findsWidgets);
      expect(find.byType(GridView), findsNothing);

      await tester.tap(find.byTooltip('Ver en grilla'));
      await tester.pumpAndSettle();

      expect(find.byType(GridView), findsOneWidget);
      expect(find.text('Otra'), findsOneWidget);
    });

    testWidgets('avisa cuando la página está truncada', (tester) async {
      final notes = _FakeNotesRepository(
        page: NotePage(
          items: [for (var index = 0; index < 3; index++) _summary(id: 'n$index')],
          total: 180,
          limit: 3,
          offset: 0,
        ),
      );
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(),
        notes: notes,
      );

      // "3 notas" a secas se leería como "tengo 3 notas".
      expect(find.textContaining('Mostrando 3 de 180'), findsOneWidget);
    });

    testWidgets('la búsqueda dispara una consulta con q después del debounce',
        (tester) async {
      final notes = _FakeNotesRepository();
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(),
        notes: notes,
      );
      final before = notes.listQueries.length;

      await tester.enterText(
        find.widgetWithText(TextField, 'Buscar…'),
        'margen',
      );
      await tester.pump(const Duration(milliseconds: 100));
      // Todavía no: el debounce evita una consulta por tecla.
      expect(notes.listQueries.length, before);

      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(notes.listQueries.last['query'], 'margen');
      expect(find.text('"margen"'), findsOneWidget);
    });

    testWidgets('el filtro por ticker se normaliza a mayúsculas', (tester) async {
      final notes = _FakeNotesRepository();
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(),
        notes: notes,
      );

      await tester.enterText(find.widgetWithText(TextField, 'Ticker'), 'nvda');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(notes.listQueries.last['ticker'], 'NVDA');
    });

    testWidgets('los tres vacíos dicen cosas distintas', (tester) async {
      final notes = _FakeNotesRepository();
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(folders: _tree),
        notes: notes,
      );

      // Sin nada: invita a escribir.
      expect(find.textContaining('Todavía no escribiste ninguna nota'),
          findsOneWidget);

      await tester.tap(find.text('Semis'));
      await tester.pumpAndSettle();
      // En una carpeta: explica que lo que cree ahí va a quedar archivado.
      expect(find.textContaining('Esta carpeta está vacía'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Buscar…'),
        'nada',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      // Con filtros: dice que el problema es el filtro, no la biblioteca.
      expect(find.textContaining('Ningún resultado con esos filtros'),
          findsOneWidget);
    });

    testWidgets('fijar desde la lista manda SOLO pinned', (tester) async {
      final notes = _FakeNotesRepository(
        page: NotePage(
          items: [_summary(id: 'n1', title: 'Tesis', folderId: 'research')],
          total: 1,
          limit: 50,
          offset: 0,
        ),
      );
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(folders: _tree),
        notes: notes,
      );

      await tester.tap(find.byTooltip('Opciones de Tesis'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fijar arriba'));
      await tester.pumpAndSettle();

      // Un PATCH completo desde la lista tendría que traerse el cuerpo primero para no borrarlo, y
      // mandar `folder_id: null` sacaría la nota de su carpeta sin que nadie lo pidiera.
      expect(notes.patches.single, {'pinned': true});
    });
  });

  // --- Editor ---------------------------------------------------------------------------------

  group('NoteEditorPanel', () {
    testWidgets('abrir una nota carga el cuerpo y la marca como guardada',
        (tester) async {
      final notes = _FakeNotesRepository(
        page: NotePage(
          items: [_summary(id: 'n1', title: 'Tesis')],
          total: 1,
          limit: 50,
          offset: 0,
        ),
        note: _note(id: 'n1', title: 'Tesis', content: '# Cuerpo\n\nDetalle.'),
      );
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(folders: _tree),
        notes: notes,
      );

      await tester.tap(find.text('Tesis'));
      await tester.pumpAndSettle();

      expect(find.text('GUARDADA'), findsOneWidget);
      expect(find.text('# Cuerpo\n\nDetalle.'), findsOneWidget);
      // El botón de guardar arranca deshabilitado: no hay nada que guardar.
      final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Guardar'),
      );
      expect(save.onPressed, isNull);
    });

    testWidgets('escribir marca "sin guardar" y guardar manda el borrador entero',
        (tester) async {
      final notes = _FakeNotesRepository(
        page: NotePage(
          items: [_summary(id: 'n1', title: 'Tesis')],
          total: 1,
          limit: 50,
          offset: 0,
        ),
        note: _note(id: 'n1', title: 'Tesis', content: 'original'),
      );
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(folders: _tree),
        notes: notes,
      );

      await tester.tap(find.text('Tesis'));
      await tester.pumpAndSettle();

      await tester.enterText(find.text('original'), 'reescrito');
      await tester.pumpAndSettle();

      // El indicador es lo que hace honesto al guardado explícito.
      expect(find.text('SIN GUARDAR'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
      await tester.pumpAndSettle();

      expect(notes.savedDrafts.single.$1, 'n1');
      expect(notes.savedDrafts.single.$2.content, 'reescrito');
      expect(find.text('Nota guardada.'), findsOneWidget);
    });

    testWidgets('la vista previa renderiza el Markdown', (tester) async {
      final notes = _FakeNotesRepository(
        page: NotePage(
          items: [_summary(id: 'n1', title: 'Tesis')],
          total: 1,
          limit: 50,
          offset: 0,
        ),
        note: _note(id: 'n1', title: 'Tesis', content: '## Riesgos\n\n- Uno'),
      );
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(),
        notes: notes,
      );

      await tester.tap(find.text('Tesis'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vista'));
      await tester.pumpAndSettle();

      expect(find.byType(MarkdownView), findsOneWidget);
      expect(find.text('Riesgos', findRichText: true), findsOneWidget);
      expect(find.text('Uno', findRichText: true), findsOneWidget);
    });

    testWidgets('una nota nueva hereda la carpeta y el ticker del filtro activo',
        (tester) async {
      final notes = _FakeNotesRepository();
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(folders: _tree),
        notes: notes,
      );

      await tester.tap(find.text('Semis'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Ticker'), 'nvda');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Nueva nota'));
      await tester.pumpAndSettle();

      expect(find.text('NUEVA'), findsOneWidget);
      // Crear una nota estando dentro de "Semis" con el filtro NVDA puesto y que aparezca en la raíz
      // sin ticker sería tirar dos decisiones que el usuario acababa de tomar.
      expect(find.text('Research / Semis'), findsWidgets);

      await tester.enterText(
        find.widgetWithText(TextField, 'Título de la nota'),
        'Nueva tesis',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
      await tester.pumpAndSettle();

      final draft = notes.createdDrafts.single;
      expect(draft.effectiveTitle, 'Nueva tesis');
      expect(draft.folderId, 'semis');
      expect(draft.normalizedTicker, 'NVDA');
    });

    testWidgets('sacar la nota de su carpeta deja el borrador sin folderId',
        (tester) async {
      final notes = _FakeNotesRepository(
        page: NotePage(
          items: [_summary(id: 'n1', title: 'Tesis', folderId: 'research')],
          total: 1,
          limit: 50,
          offset: 0,
        ),
        note: _note(id: 'n1', title: 'Tesis', folderId: 'research'),
      );
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(folders: _tree),
        notes: notes,
      );

      await tester.tap(find.text('Tesis'));
      await tester.pumpAndSettle();
      expect(find.text('Research'), findsWidgets);

      await tester.tap(find.byTooltip('Sacar de la carpeta'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
      await tester.pumpAndSettle();

      // El repositorio traduce esto a un `folder_id: null` EXPLÍCITO (ver el grupo de payloads):
      // omitirlo dejaría la nota archivada y el "sacar de la carpeta" no haría nada.
      expect(notes.savedDrafts.single.$2.folderId, isNull);
    });

    testWidgets('avisa antes de descartar cambios sin guardar', (tester) async {
      final notes = _FakeNotesRepository(
        page: NotePage(
          items: [
            _summary(id: 'n1', title: 'Tesis'),
            _summary(id: 'n2', title: 'Otra nota'),
          ],
          total: 2,
          limit: 50,
          offset: 0,
        ),
        note: _note(id: 'n1', title: 'Tesis', content: 'original'),
      );
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(),
        notes: notes,
      );

      await tester.tap(find.text('Tesis'));
      await tester.pumpAndSettle();
      await tester.enterText(find.text('original'), 'a medio escribir');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Otra nota'));
      await tester.pumpAndSettle();

      // Es el precio del guardado explícito: sin este aviso, un clic tiraría el texto en silencio.
      expect(find.text('Cambios sin guardar'), findsOneWidget);

      await tester.tap(find.text('Seguir editando'));
      await tester.pumpAndSettle();
      expect(find.text('a medio escribir'), findsOneWidget);
    });

    testWidgets('un error al guardar se muestra y no cierra el editor',
        (tester) async {
      final notes = _FakeNotesRepository(
        page: NotePage(
          items: [_summary(id: 'n1', title: 'Tesis')],
          total: 1,
          limit: 50,
          offset: 0,
        ),
        note: _note(id: 'n1', title: 'Tesis', content: 'original'),
      );
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(),
        notes: notes,
      );

      await tester.tap(find.text('Tesis'));
      await tester.pumpAndSettle();
      await tester.enterText(find.text('original'), 'nuevo');
      await tester.pumpAndSettle();

      notes.failure = DioException(
        requestOptions: RequestOptions(path: '/notes/n1'),
        response: Response(
          requestOptions: RequestOptions(path: '/notes/n1'),
          statusCode: 422,
          data: {'detail': 'El cuerpo es demasiado largo.'},
        ),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
      await tester.pumpAndSettle();

      expect(find.text('El cuerpo es demasiado largo.'), findsOneWidget);
      // El texto no se pierde: sigue en pantalla y sigue marcado como sin guardar.
      expect(find.text('nuevo'), findsOneWidget);
      expect(find.text('SIN GUARDAR'), findsOneWidget);
    });

    testWidgets('sin nada abierto el panel invita a elegir una nota',
        (tester) async {
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(),
        notes: _FakeNotesRepository(),
      );

      expect(find.textContaining('Elegí una nota de la lista'), findsOneWidget);
    });
  });

  // --- Layout adaptativo ----------------------------------------------------------------------

  group('layout adaptativo', () {
    testWidgets('en pantalla ancha se ven los tres paneles', (tester) async {
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(folders: _tree),
        notes: _FakeNotesRepository(),
        size: const Size(1500, 1000),
      );

      expect(find.text('Investment Lab'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Todas las notas'), findsOneWidget);
      expect(find.textContaining('Elegí una nota de la lista'), findsOneWidget);
      expect(find.byType(Drawer), findsNothing);
    });

    testWidgets('en un ancho intermedio el editor no ocupa una tercera columna',
        (tester) async {
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(folders: _tree),
        notes: _FakeNotesRepository(),
        size: const Size(900, 1000),
      );

      // Sidebar + explorador, sin el placeholder del editor: tres columnas en 900px dejarían las
      // tres ilegibles.
      expect(find.widgetWithText(ListTile, 'Todas las notas'), findsOneWidget);
      expect(find.textContaining('Elegí una nota de la lista'), findsNothing);
    });

    testWidgets('en mobile las carpetas viven en un Drawer', (tester) async {
      await _pumpLab(
        tester,
        folders: _FakeFoldersRepository(folders: _tree),
        notes: _FakeNotesRepository(),
        size: const Size(420, 900),
      );

      // Un sidebar fijo en un teléfono se comería la mitad del ancho de la lista.
      expect(find.widgetWithText(ListTile, 'Todas las notas'), findsNothing);
      expect(find.byIcon(Icons.menu), findsOneWidget);

      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();

      expect(find.byType(Drawer), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Todas las notas'), findsOneWidget);
    });
  });
}
