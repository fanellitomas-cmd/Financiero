/// Modelos de `/api/v1/notes` — las notas de investigación del Investment Lab.
///
/// Espejan `app/schemas/note.py`. Hay DOS formas de una nota a propósito:
///
///   - [NoteSummary]: lo que devuelve el listado, SIN el cuerpo. El backend manda `excerpt` y
///     `content_length` en su lugar, porque una carpeta con 50 tesis serían megabytes por cada
///     apertura de la pantalla para texto que no se muestra hasta abrir una nota.
///   - [Note]: la nota completa, de `GET /notes/{id}`. Es lo que edita el editor.
///
/// No se unifican en una clase con `content` nullable justamente para que sea imposible mostrar el
/// cuerpo de un resumen creyendo que está vacío cuando en realidad no se pidió.
library;

import 'package:flutter/foundation.dart';

@immutable
class Note {
  const Note({
    required this.id,
    required this.folderId,
    required this.ticker,
    required this.title,
    required this.content,
    required this.pinned,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Note.fromJson(Map<String, dynamic> json) => Note(
        id: json['id'] as String,
        folderId: json['folder_id'] as String?,
        ticker: json['ticker'] as String?,
        title: json['title'] as String,
        content: json['content'] as String? ?? '',
        pinned: json['pinned'] as bool? ?? false,
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );

  final String id;
  final String? folderId;

  /// Símbolo al que la nota se refiere. Independiente de la carpeta: una nota de NVDA puede vivir en
  /// cualquier carpeta o en ninguna, y la Ficha del activo la encuentra igual por acá.
  final String? ticker;

  final String title;
  final String content;
  final bool pinned;
  final DateTime createdAt;
  final DateTime updatedAt;
}

@immutable
class NoteSummary {
  const NoteSummary({
    required this.id,
    required this.folderId,
    required this.ticker,
    required this.title,
    required this.pinned,
    required this.createdAt,
    required this.updatedAt,
    required this.excerpt,
    required this.contentLength,
  });

  factory NoteSummary.fromJson(Map<String, dynamic> json) => NoteSummary(
        id: json['id'] as String,
        folderId: json['folder_id'] as String?,
        ticker: json['ticker'] as String?,
        title: json['title'] as String,
        pinned: json['pinned'] as bool? ?? false,
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
        excerpt: json['excerpt'] as String? ?? '',
        contentLength: json['content_length'] as int? ?? 0,
      );

  final String id;
  final String? folderId;
  final String? ticker;
  final String title;
  final bool pinned;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Vista previa del cuerpo, con los saltos de línea ya colapsados por el backend.
  final String excerpt;

  /// Largo real del cuerpo. Deja distinguir una nota vacía de una larga sin traerla: `excerpt`
  /// vacío puede ser tanto "no escribí nada" como "el cuerpo son solo espacios".
  final int contentLength;

  bool get isEmpty => contentLength == 0;
}

@immutable
class NotePage {
  const NotePage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  factory NotePage.fromJson(Map<String, dynamic> json) => NotePage(
        items: ((json['items'] as List?) ?? [])
            .map((item) => NoteSummary.fromJson(item as Map<String, dynamic>))
            .toList(),
        total: json['total'] as int? ?? 0,
        limit: json['limit'] as int? ?? 50,
        offset: json['offset'] as int? ?? 0,
      );

  static const empty = NotePage(items: [], total: 0, limit: 50, offset: 0);

  final List<NoteSummary> items;

  /// Total del filtro, no de la página: es lo que el contador del explorador muestra.
  final int total;

  final int limit;
  final int offset;

  /// `true` cuando el `total` es mayor que lo que se trajo. La UI lo dice explícitamente en vez de
  /// dejar creer que la lista está completa.
  bool get hasMore => offset + items.length < total;
}

/// Un cambio de un campo que **puede quedar en `null` a propósito**.
///
/// Existe por una asimetría real del contrato: en `PATCH /notes/{id}`, omitir `folder_id` significa
/// "dejala donde está" y mandarlo en `null` significa "sacala de la carpeta". Con un simple
/// `String?` esas dos intenciones colapsan en el mismo valor y desarchivar una nota sería imposible
/// de expresar. `null` en el parámetro = omitir; `FieldUpdate.clear()` = mandar null explícito.
@immutable
class FieldUpdate<T> {
  const FieldUpdate.to(this.value);
  const FieldUpdate.clear() : value = null;

  final T? value;
}

/// Cuerpo de `PATCH /notes/{id}`.
///
/// Función aparte del repositorio y no un mapa armado inline porque acá vive la regla más fácil de
/// romper de todo el módulo: **una clave ausente y una clave en `null` significan cosas distintas**.
/// Aislarla la hace verificable sin levantar HTTP.
Map<String, dynamic> noteUpdatePayload({
  String? title,
  String? content,
  bool? pinned,
  FieldUpdate<String>? folderId,
  FieldUpdate<String>? ticker,
}) =>
    {
      if (title != null) 'title': title,
      if (content != null) 'content': content,
      if (pinned != null) 'pinned': pinned,
      // El `if` mira el WRAPPER, no su valor: `FieldUpdate.clear()` está presente y emite
      // `'folder_id': null`, que es lo que el backend lee como "sacala de la carpeta".
      if (folderId != null) 'folder_id': folderId.value,
      if (ticker != null) 'ticker': ticker.value,
    };

/// Cuerpo de `PATCH /folders/{id}`, con la misma distinción para `parent_id`: ausente deja la
/// carpeta donde está, `null` explícito la manda a la raíz.
Map<String, dynamic> folderUpdatePayload({
  String? name,
  FieldUpdate<String>? parentId,
}) =>
    {
      if (name != null) 'name': name,
      if (parentId != null) 'parent_id': parentId.value,
    };

/// Lo que el editor tiene en pantalla, guardado o no.
///
/// Separado de [Note] porque una nota nueva todavía no tiene id ni fechas, y porque el editor
/// necesita comparar contra el original para saber si hay cambios sin guardar — algo que no se
/// puede hacer si el modelo editable es el mismo objeto que llegó del servidor.
@immutable
class NoteDraft {
  const NoteDraft({
    required this.title,
    required this.content,
    required this.folderId,
    required this.ticker,
    required this.pinned,
  });

  /// Borrador vacío, opcionalmente ya ubicado en una carpeta y/o vinculado a un símbolo: crear una
  /// nota desde la carpeta "Semiconductores" o desde la Ficha de NVDA debería arrancar con ese
  /// contexto puesto, no obligar a elegirlo de nuevo.
  factory NoteDraft.blank({
    String? folderId,
    String? ticker,
    String title = '',
    String content = '',
  }) =>
      NoteDraft(
        title: title,
        content: content,
        folderId: folderId,
        ticker: ticker,
        pinned: false,
      );

  factory NoteDraft.fromNote(Note note) => NoteDraft(
        title: note.title,
        content: note.content,
        folderId: note.folderId,
        ticker: note.ticker,
        pinned: note.pinned,
      );

  final String title;
  final String content;
  final String? folderId;
  final String? ticker;
  final bool pinned;

  NoteDraft copyWith({
    String? title,
    String? content,
    bool clearFolder = false,
    String? folderId,
    bool clearTicker = false,
    String? ticker,
    bool? pinned,
  }) =>
      NoteDraft(
        title: title ?? this.title,
        content: content ?? this.content,
        folderId: clearFolder ? null : (folderId ?? this.folderId),
        ticker: clearTicker ? null : (ticker ?? this.ticker),
        pinned: pinned ?? this.pinned,
      );

  /// El título que se va a guardar. Vacío no es aceptable para el backend (422), y pedirle al
  /// usuario que titule una nota antes de escribirla es un obstáculo tonto: se pone un default.
  String get effectiveTitle {
    final trimmed = title.trim();
    return trimmed.isEmpty ? 'Nota sin título' : trimmed;
  }

  /// El símbolo normalizado, o `null` si el campo quedó vacío. Se normaliza acá y no solo en el
  /// backend para que el chip del editor muestre lo mismo que se va a guardar.
  String? get normalizedTicker {
    final trimmed = ticker?.trim().toUpperCase();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  /// ¿Hay algo que guardar respecto de lo que está en el servidor?
  ///
  /// Se compara contra la nota original y no contra un flag que se prende al tipear: así, escribir
  /// una palabra y borrarla vuelve a dejar el editor "limpio" en vez de quedar marcado como sucio
  /// para siempre.
  bool differsFrom(Note note) =>
      effectiveTitle != note.title ||
      content != note.content ||
      folderId != note.folderId ||
      normalizedTicker != note.ticker ||
      pinned != note.pinned;

  /// Cuerpo de `POST /notes`.
  Map<String, dynamic> toCreateJson() => {
        'title': effectiveTitle,
        'content': content,
        if (folderId != null) 'folder_id': folderId,
        if (normalizedTicker != null) 'ticker': normalizedTicker,
        'pinned': pinned,
      };
}
