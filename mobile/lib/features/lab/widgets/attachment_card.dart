import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../data/note_attachment.dart';
import '../data/note_formatting.dart';
import '../presentation/attachments_controller.dart';
import 'chart_markup_editor.dart';
import 'drawing_painter.dart';

/// Las capturas de una nota, incrustadas debajo del cuerpo.
///
/// Se muestran SIEMPRE que la nota tenga alguna, incluso en el editor de texto: una tesis técnica
/// sin el gráfico que la motivó pierde la mitad del argumento, y esconderla detrás de una pestaña
/// haría que el usuario no recuerde que la guardó.
class NoteAttachmentsSection extends ConsumerWidget {
  const NoteAttachmentsSection({super.key, required this.noteId});

  final String noteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(noteAttachmentsProvider(noteId));
    final attachments = async.valueOrNull ?? const <NoteAttachment>[];

    // Sin capturas no se muestra NADA, ni un encabezado vacío: la mayoría de las notas son solo
    // texto, y una sección "Gráficos (0)" en todas sería ruido permanente.
    if (attachments.isEmpty) {
      if (async.hasError) {
        return _AttachmentsError(
          message: describeApiError(async.error!),
          onRetry: () => ref.invalidate(noteAttachmentsProvider(noteId)),
        );
      }
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.candlestick_chart_outlined,
                size: 15, color: AppTheme.accent),
            const SizedBox(width: 6),
            Text(
              attachments.length == 1
                  ? 'Análisis Técnico · 1 gráfico'
                  : 'Análisis Técnico · ${attachments.length} gráficos',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (final attachment in attachments) ...[
          AttachmentCard(attachment: attachment),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

/// Una captura con sus anotaciones dibujadas encima.
///
/// La miniatura NO es una imagen aparte "quemada": es la misma imagen con el mismo painter que usa
/// el editor. Por eso lo que se ve acá es exactamente lo que se guardó, y una anotación editada
/// aparece al instante sin volver a bajar nada.
class AttachmentCard extends ConsumerWidget {
  const AttachmentCard({super.key, required this.attachment});

  final NoteAttachment attachment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AttachmentPreview(attachment: attachment),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                if (attachment.ticker != null) ...[
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: AppTheme.badgeDecoration(AppTheme.accent),
                    child: Text(
                      attachment.ticker!,
                      style: AppTheme.numeric(fontSize: 10, color: AppTheme.accent)
                          .copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (attachment.caption != null)
                        Text(
                          attachment.caption!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      Text(
                        [
                          formatRelativeTime(attachment.createdAt),
                          // Cuántas anotaciones tiene, para distinguir de un vistazo una captura ya
                          // trabajada de una que se pegó y quedó pendiente.
                          attachment.hasAnnotations
                              ? '${attachment.shapeCount} '
                                  '${attachment.shapeCount == 1 ? "trazo" : "trazos"}'
                              : 'sin anotar',
                        ].join(' · '),
                        style: AppTheme.numeric(
                          fontSize: 10,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                _AttachmentMenu(attachment: attachment),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AttachmentPreview extends ConsumerWidget {
  const _AttachmentPreview({required this.attachment});

  final NoteAttachment attachment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final imageAsync = ref.watch(attachmentImageProvider(attachment.imageUrl));

    return AspectRatio(
      // Se reserva el espacio con la proporción declarada ANTES de que la imagen baje: sin esto, la
      // nota salta de layout cuando cada captura termina de cargar.
      aspectRatio: attachment.aspectRatio ?? 16 / 9,
      child: InkWell(
        onTap: () async {
          final saved = await ChartMarkupEditor.open(context, attachment);
          if (!saved || !context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Anotaciones guardadas.')),
          );
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            imageAsync.when(
              data: (bytes) => Image.memory(
                bytes,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
              ),
              loading: () => const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              error: (error, stackTrace) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    describeApiError(error),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 11),
                  ),
                ),
              ),
            ),
            // Las anotaciones se pintan aunque la imagen todavía no haya bajado: son el dato liviano
            // de los dos, y verlas primero confirma que la captura es la correcta.
            if (attachment.hasAnnotations)
              CustomPaint(
                painter: DrawingPainter(
                  shapes: attachment.drawing.drawable,
                  aspectRatio: attachment.aspectRatio,
                  referenceWidth: attachment.width?.toDouble(),
                ),
              ),
            Positioned(
              right: 8,
              top: 8,
              child: _EditHint(annotated: attachment.hasAnnotations),
            ),
          ],
        ),
      ),
    );
  }
}

/// Insignia de "editable".
///
/// Existe porque una imagen dentro de una nota no se lee como un botón: sin la pista, nadie
/// descubriría que tocarla abre el editor de anotaciones.
class _EditHint extends StatelessWidget {
  const _EditHint({required this.annotated});

  final bool annotated;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.background.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            annotated ? Icons.edit_outlined : Icons.draw_outlined,
            size: 12,
            color: AppTheme.accent,
          ),
          const SizedBox(width: 4),
          Text(
            annotated ? 'Editar trazos' : 'Anotar',
            style: const TextStyle(fontSize: 10, color: AppTheme.accent),
          ),
        ],
      ),
    );
  }
}

class _AttachmentMenu extends ConsumerWidget {
  const _AttachmentMenu({required this.attachment});

  final NoteAttachment attachment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<_AttachmentAction>(
      tooltip: 'Opciones de la captura',
      icon: const Icon(Icons.more_vert, size: 18),
      onSelected: (action) async {
        final messenger = ScaffoldMessenger.of(context);
        switch (action) {
          case _AttachmentAction.annotate:
            await ChartMarkupEditor.open(context, attachment);
          case _AttachmentAction.delete:
            if (!await _confirmDelete(context)) return;
            try {
              await ref.read(attachmentActionsProvider).remove(attachment);
              messenger.showSnackBar(
                const SnackBar(content: Text('Captura eliminada.')),
              );
            } on Object catch (error) {
              messenger.showSnackBar(
                SnackBar(content: Text(describeApiError(error))),
              );
            }
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _AttachmentAction.annotate,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(Icons.draw_outlined, size: 18),
            title: Text('Anotar el gráfico'),
          ),
        ),
        PopupMenuItem(
          value: _AttachmentAction.delete,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(Icons.delete_outline, size: 18),
            title: Text('Eliminar captura'),
          ),
        ),
      ],
    );
  }

  static Future<bool> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Eliminar captura'),
        content: const Text(
          'Se borra el gráfico y sus anotaciones. No se puede deshacer.',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.bearish),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}

enum _AttachmentAction { annotate, delete }

class _AttachmentsError extends StatelessWidget {
  const _AttachmentsError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.neutral.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.neutral.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.image_not_supported_outlined,
              size: 16, color: AppTheme.neutral),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              // Se avisa en vez de esconder la sección: si la nota TIENE capturas y no se pudieron
              // leer, un espacio en blanco haría creer que se perdieron.
              'No se pudieron cargar los gráficos de esta nota. $message',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Reintentar')),
        ],
      ),
    );
  }
}
