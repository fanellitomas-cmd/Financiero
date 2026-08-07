import '../../../core/network/api_client.dart';
import 'folder.dart';
import 'note.dart';

/// Envuelve `/api/v1/folders` (`app/api/v1/folders.py`) — el árbol de carpetas del Investment Lab.
class FoldersRepository {
  FoldersRepository(this._apiClient);

  final ApiClient _apiClient;

  /// El árbol completo como lista plana, ya ordenada por ruta.
  Future<List<Folder>> list() async {
    final response = await _apiClient.dio.get('/folders');
    return (response.data as List)
        .map((folder) => Folder.fromJson(folder as Map<String, dynamic>))
        .toList();
  }

  /// Crea una carpeta. `parentId` en `null` la crea en la raíz.
  ///
  /// Puede fallar con 409 (ya hay una hermana con ese nombre) o 422 (pasaría el límite de niveles):
  /// los dos son mensajes que el backend redacta y que la UI muestra tal cual.
  Future<Folder> create(String name, {String? parentId}) async {
    final response = await _apiClient.dio.post(
      '/folders',
      data: {
        'name': name,
        if (parentId != null) 'parent_id': parentId,
      },
    );
    return Folder.fromJson(response.data as Map<String, dynamic>);
  }

  /// Renombra y/o mueve una carpeta.
  ///
  /// `parentId` sigue la misma convención que en las notas: omitirlo deja la carpeta donde está y
  /// `FieldUpdate.clear()` la manda a la raíz. Sin esa distinción, sacar una subcarpeta de su padre
  /// no se podría expresar.
  Future<Folder> update(
    String folderId, {
    String? name,
    FieldUpdate<String>? parentId,
  }) async {
    final response = await _apiClient.dio.patch(
      '/folders/$folderId',
      data: folderUpdatePayload(name: name, parentId: parentId),
    );
    return Folder.fromJson(response.data as Map<String, dynamic>);
  }

  /// Elimina una carpeta y devuelve el resumen de lo que pasó.
  ///
  /// Con `cascade: false` (el default del backend) **no se pierde ninguna nota**: las de la carpeta
  /// pasan a la raíz y las subcarpetas suben un nivel. Con `cascade: true` se borra el subárbol
  /// completo con sus notas, y por eso la UI lo pide con una confirmación aparte.
  Future<FolderDeletionResult> remove(
    String folderId, {
    bool cascade = false,
  }) async {
    final response = await _apiClient.dio.delete(
      '/folders/$folderId',
      queryParameters: {'cascade': cascade},
    );
    return FolderDeletionResult.fromJson(response.data as Map<String, dynamic>);
  }
}
