/// Modelos de `/api/v1/folders` — el árbol de carpetas del Investment Lab.
///
/// Espeja `app/schemas/folder.py`. Lo importante del contrato: el backend devuelve una lista
/// **plana** ya ordenada por ruta, con `depth` y `path` calculados. No hay que reconstruir la
/// jerarquía del lado del cliente — se recorre una vez y se indenta por `depth`.
library;

import 'package:flutter/foundation.dart';

@immutable
class Folder {
  const Folder({
    required this.id,
    required this.name,
    required this.parentId,
    required this.createdAt,
    required this.updatedAt,
    required this.depth,
    required this.path,
    required this.noteCount,
    required this.subfolderCount,
  });

  factory Folder.fromJson(Map<String, dynamic> json) => Folder(
        id: json['id'] as String,
        name: json['name'] as String,
        parentId: json['parent_id'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
        depth: json['depth'] as int? ?? 0,
        path: json['path'] as String? ?? (json['name'] as String),
        noteCount: json['note_count'] as int? ?? 0,
        subfolderCount: json['subfolder_count'] as int? ?? 0,
      );

  final String id;
  final String name;
  final String? parentId;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 0 para las carpetas de la raíz. Es de lo único que depende la indentación del árbol.
  final int depth;

  /// Ruta legible completa ("Research / Semiconductores"). Sirve para el breadcrumb del editor y
  /// para el selector de carpeta, donde un nombre suelto sería ambiguo entre dos "NVDA" de
  /// distintas ramas.
  final String path;

  /// Notas DIRECTAMENTE en esta carpeta — no incluye las de sus subcarpetas. Coincide con lo que
  /// muestra el explorador al seleccionarla, que es justamente el punto: un total recursivo haría
  /// que el número prometa más de lo que se ve al abrirla.
  final int noteCount;

  final int subfolderCount;

  bool get isRoot => parentId == null;
}

/// Resultado de `DELETE /api/v1/folders/{id}`.
///
/// El endpoint devuelve 200 con este resumen en vez de un 204 mudo porque **por defecto no se
/// pierde nada**: las notas de la carpeta pasan a la raíz y las subcarpetas suben un nivel. Quien
/// borró "Research" esperando perder todo necesita ver que sus notas siguen estando, y quien pidió
/// cascada necesita ver cuánto se borró. La UI convierte esto en el texto del SnackBar.
@immutable
class FolderDeletionResult {
  const FolderDeletionResult({
    required this.deletedFolderId,
    required this.cascade,
    required this.reparentedFolders,
    required this.detachedNotes,
    required this.deletedFolders,
    required this.deletedNotes,
  });

  factory FolderDeletionResult.fromJson(Map<String, dynamic> json) =>
      FolderDeletionResult(
        deletedFolderId: json['deleted_folder_id'] as String,
        cascade: json['cascade'] as bool? ?? false,
        reparentedFolders: json['reparented_folders'] as int? ?? 0,
        detachedNotes: json['detached_notes'] as int? ?? 0,
        deletedFolders: json['deleted_folders'] as int? ?? 0,
        deletedNotes: json['deleted_notes'] as int? ?? 0,
      );

  final String deletedFolderId;
  final bool cascade;
  final int reparentedFolders;
  final int detachedNotes;
  final int deletedFolders;
  final int deletedNotes;

  /// Qué pasó, en una frase, para el SnackBar posterior al borrado.
  ///
  /// Se nombra explícitamente lo que sobrevivió (o lo que se destruyó) porque es la información que
  /// el usuario no puede deducir de la pantalla: después del borrado, las notas que subieron a la
  /// raíz están mezcladas con las que ya estaban ahí.
  String describe(String folderName) {
    if (cascade) {
      final parts = <String>[
        if (deletedFolders > 0)
          '$deletedFolders ${deletedFolders == 1 ? "subcarpeta" : "subcarpetas"}',
        if (deletedNotes > 0)
          '$deletedNotes ${deletedNotes == 1 ? "nota" : "notas"}',
      ];
      if (parts.isEmpty) return 'Se eliminó «$folderName» (estaba vacía).';
      return 'Se eliminó «$folderName» junto con ${parts.join(" y ")}.';
    }

    final parts = <String>[
      if (reparentedFolders > 0)
        '${reparentedFolders == 1 ? "1 subcarpeta subió" : "$reparentedFolders subcarpetas subieron"} un nivel',
      if (detachedNotes > 0)
        '${detachedNotes == 1 ? "1 nota volvió" : "$detachedNotes notas volvieron"} a la raíz',
    ];
    if (parts.isEmpty) return 'Se eliminó «$folderName» (estaba vacía).';
    return 'Se eliminó «$folderName». ${_capitalize(parts.join(" y "))}.';
  }

  static String _capitalize(String value) =>
      value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);
}
