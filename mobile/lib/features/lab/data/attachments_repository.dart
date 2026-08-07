import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
import 'note_attachment.dart';

/// Envuelve `/api/v1/notes/{id}/attachments` (`app/api/v1/note_attachments.py`).
///
/// Dos endpoints de lectura y no uno, igual que con las notas: [list] devuelve metadatos y la capa
/// de dibujo, y [loadImage] baja los píxeles. Traer las imágenes con el listado haría que abrir una
/// nota con diez capturas transfiera decenas de megabytes en cada apertura.
class AttachmentsRepository {
  AttachmentsRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<List<NoteAttachment>> list(String noteId) async {
    final response = await _apiClient.dio.get('/notes/$noteId/attachments');
    return (response.data as List)
        .map((item) => NoteAttachment.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// Sube una captura con su capa de dibujo.
  ///
  /// La imagen viaja en base64 porque el cuerpo es JSON: el dibujo tiene que llegar en el MISMO
  /// request que los píxeles, y un `multipart` con un campo JSON adentro es incómodo desde Dart. El
  /// backend la guarda en crudo.
  Future<NoteAttachment> create(String noteId, AttachmentDraft draft) async {
    final response = await _apiClient.dio.post(
      '/notes/$noteId/attachments',
      data: {
        'image_data': base64Encode(draft.imageBytes),
        'content_type': draft.contentType,
        if (draft.ticker != null) 'ticker': draft.ticker,
        if (draft.caption != null) 'caption': draft.caption,
        if (draft.source != null) 'source': draft.source,
        if (draft.width != null) 'width': draft.width,
        if (draft.height != null) 'height': draft.height,
        'drawing': draft.drawing.toJson(),
      },
    );
    return NoteAttachment.fromJson(response.data as Map<String, dynamic>);
  }

  /// Reemplaza la capa de dibujo completa.
  ///
  /// PUT y no PATCH: el canvas conoce su estado entero y lo manda entero. Con semántica de parche,
  /// "borré la última línea" no se podría expresar.
  ///
  /// `caption` y `ticker` solo viajan si se pasan; para desvincular el símbolo hay que pasar
  /// `clearTicker: true`, que emite el `null` explícito que el backend lee como "sacalo".
  Future<NoteAttachment> updateDrawing(
    String noteId,
    String attachmentId,
    DrawingLayer drawing, {
    String? caption,
    String? ticker,
    bool clearTicker = false,
  }) async {
    final response = await _apiClient.dio.put(
      '/notes/$noteId/attachments/$attachmentId',
      data: {
        'drawing': drawing.toJson(),
        if (caption != null) 'caption': caption,
        if (clearTicker) 'ticker': null else if (ticker != null) 'ticker': ticker,
      },
    );
    return NoteAttachment.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> remove(String noteId, String attachmentId) =>
      _apiClient.dio.delete('/notes/$noteId/attachments/$attachmentId');

  /// Baja los bytes de una captura.
  ///
  /// Se piden por Dio y no con `Image.network` porque el endpoint está autenticado: el interceptor
  /// del `ApiClient` es el que pone el Bearer, y armar los headers a mano en cada `Image` duplicaría
  /// esa lógica (y el manejo del 401) en la capa de widgets.
  ///
  /// `imageUrl` viene del backend con el prefijo `/api/v1`, que ya está en el `baseUrl` de Dio: se
  /// saca para no pedir `/api/v1/api/v1/...`.
  Future<Uint8List> loadImage(String imageUrl) async {
    const prefix = '/api/v1';
    final path = imageUrl.startsWith(prefix)
        ? imageUrl.substring(prefix.length)
        : imageUrl;

    final response = await _apiClient.dio.get<List<int>>(
      path,
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(response.data ?? const []);
  }
}
