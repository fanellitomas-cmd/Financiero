import 'package:dio/dio.dart';

import '../../../core/network/api_client.dart';
import 'note.dart';

/// Envuelve `/api/v1/notes` (`app/api/v1/notes.py`) — las notas de investigación del Lab.
///
/// Dos endpoints de lectura y no uno: [list] devuelve resúmenes sin cuerpo (lo que muestra el
/// explorador) y [get] devuelve la nota completa (lo que edita el editor). Pedir siempre el cuerpo
/// haría que abrir una carpeta con 50 tesis baje megabytes de texto que nadie va a leer todavía.
class NotesRepository {
  NotesRepository(this._apiClient);

  final ApiClient _apiClient;

  /// Listado filtrable y paginado.
  ///
  /// `rootOnly` es un parámetro aparte de `folderId` y no un valor especial suyo: omitir `folderId`
  /// significa "de cualquier carpeta", así que "las notas sin carpeta" necesita su propia pregunta.
  /// El backend le da prioridad si vienen los dos.
  ///
  /// `cancelToken` para la búsqueda mientras se tipea: una consulta lenta que llega después de una
  /// más nueva sobreescribiría los resultados correctos con los viejos.
  Future<NotePage> list({
    String? folderId,
    bool rootOnly = false,
    String? ticker,
    String? query,
    int limit = 50,
    int offset = 0,
    CancelToken? cancelToken,
  }) async {
    final response = await _apiClient.dio.get(
      '/notes',
      queryParameters: {
        if (folderId != null) 'folder_id': folderId,
        if (rootOnly) 'root_only': true,
        if (ticker != null && ticker.isNotEmpty) 'ticker': ticker,
        if (query != null && query.isNotEmpty) 'q': query,
        'limit': limit,
        'offset': offset,
      },
      cancelToken: cancelToken,
    );
    return NotePage.fromJson(response.data as Map<String, dynamic>);
  }

  Future<Note> get(String noteId) async {
    final response = await _apiClient.dio.get('/notes/$noteId');
    return Note.fromJson(response.data as Map<String, dynamic>);
  }

  Future<Note> create(NoteDraft draft) async {
    final response = await _apiClient.dio.post(
      '/notes',
      data: draft.toCreateJson(),
    );
    return Note.fromJson(response.data as Map<String, dynamic>);
  }

  /// PATCH parcial. Un parámetro en `null` **no se manda**; para vaciar `folder_id` o `ticker` hay
  /// que pasar `FieldUpdate.clear()`, que sí emite un `null` explícito.
  ///
  /// Esa distinción es la que permite dos operaciones distintas con el mismo endpoint: fijar una
  /// nota desde la lista (solo `pinned`, sin tocar ni mandar el cuerpo de 40 KB) y guardarla entera
  /// desde el editor.
  Future<Note> update(
    String noteId, {
    String? title,
    String? content,
    bool? pinned,
    FieldUpdate<String>? folderId,
    FieldUpdate<String>? ticker,
  }) async {
    final response = await _apiClient.dio.patch(
      '/notes/$noteId',
      data: noteUpdatePayload(
        title: title,
        content: content,
        pinned: pinned,
        folderId: folderId,
        ticker: ticker,
      ),
    );
    return Note.fromJson(response.data as Map<String, dynamic>);
  }

  /// Guarda el borrador completo de una nota existente.
  ///
  /// Manda TODOS los campos, incluidos los que quedaron vacíos como `null` explícito: el editor es
  /// un editor de estado completo, así que "el ticker está vacío" significa "quiero que no tenga
  /// ticker" y no "no lo cambies".
  Future<Note> save(String noteId, NoteDraft draft) => update(
        noteId,
        title: draft.effectiveTitle,
        content: draft.content,
        pinned: draft.pinned,
        folderId: draft.folderId == null
            ? const FieldUpdate<String>.clear()
            : FieldUpdate<String>.to(draft.folderId),
        ticker: draft.normalizedTicker == null
            ? const FieldUpdate<String>.clear()
            : FieldUpdate<String>.to(draft.normalizedTicker),
      );

  Future<void> remove(String noteId) => _apiClient.dio.delete('/notes/$noteId');
}
