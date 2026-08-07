import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../data/note_attachment.dart';

/// Providers de las capturas de gráficos adjuntas a una nota.

/// Los adjuntos de una nota, con sus metadatos y su capa de dibujo (sin los píxeles).
final noteAttachmentsProvider =
    FutureProvider.autoDispose.family<List<NoteAttachment>, String>(
  (ref, noteId) => ref.watch(attachmentsRepositoryProvider).list(noteId),
);

/// Los bytes de una captura.
///
/// Provider aparte y cacheado por URL: la misma imagen se muestra en la miniatura de la nota y en el
/// editor a pantalla completa, y bajarla dos veces sería pedir el mismo megabyte dos veces en la
/// misma pantalla.
///
/// `keepAlive` a propósito, contra la costumbre del resto de la app: los bytes de una captura NO
/// cambian nunca (el backend los sirve como `immutable`, y editar las anotaciones no los toca), así
/// que descartarlos al cerrar el editor obligaría a volver a bajarlos al reabrirlo.
final attachmentImageProvider =
    FutureProvider.family<Uint8List, String>((ref, imageUrl) {
  return ref.watch(attachmentsRepositoryProvider).loadImage(imageUrl);
});

/// Acciones de escritura sobre los adjuntos.
///
/// Viven en un notifier y no en las pantallas porque cada mutación invalida más de un provider, y
/// esa lista es fácil de olvidar en un call site: subir una captura cambia la lista de adjuntos de
/// la nota Y el `content_length` que muestra el explorador si además se editó el cuerpo.
class AttachmentActions {
  AttachmentActions(this._ref);

  final Ref _ref;

  Future<NoteAttachment> upload(String noteId, AttachmentDraft draft) async {
    final created =
        await _ref.read(attachmentsRepositoryProvider).create(noteId, draft);
    _ref.invalidate(noteAttachmentsProvider(noteId));
    return created;
  }

  /// Guarda la capa de dibujo. NO invalida [attachmentImageProvider]: los píxeles no cambiaron, y
  /// tirar la caché haría que guardar una flecha vuelva a bajar la captura entera.
  Future<NoteAttachment> saveDrawing(
    String noteId,
    String attachmentId,
    DrawingLayer drawing, {
    String? caption,
  }) async {
    final updated = await _ref.read(attachmentsRepositoryProvider).updateDrawing(
          noteId,
          attachmentId,
          drawing,
          caption: caption,
        );
    _ref.invalidate(noteAttachmentsProvider(noteId));
    return updated;
  }

  Future<void> remove(NoteAttachment attachment) async {
    await _ref
        .read(attachmentsRepositoryProvider)
        .remove(attachment.noteId, attachment.id);
    _ref.invalidate(noteAttachmentsProvider(attachment.noteId));
    // Los bytes sí se descartan acá: el adjunto ya no existe, y dejarlos en memoria sería retener
    // un megabyte por una captura que nadie va a volver a pedir.
    _ref.invalidate(attachmentImageProvider(attachment.imageUrl));
  }
}

final attachmentActionsProvider =
    Provider<AttachmentActions>((ref) => AttachmentActions(ref));
