import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/degradation_banner.dart';
import '../data/corporate_formatting.dart';
import '../data/corporate_models.dart';
import '../data/corporate_note_snippet.dart';
import '../presentation/corporate_controller.dart';
import 'corporate_badges.dart';
import 'save_to_lab_sheet.dart';

/// Pestaña "Noticias": el feed de novedades y rumores, clasificado.
///
/// La pieza que no se puede sacar de esta pantalla es la **advertencia de procedencia**: la categoría
/// y el sentimiento salen de un heurístico de palabras clave sobre el titular, y el feed lo dice arriba
/// una vez y en el tooltip de cada badge. Sin eso, un "BAJISTA" al lado de un titular se lee como el
/// veredicto de un analista.
class CorporateNewsTab extends ConsumerWidget {
  const CorporateNewsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(newsQueryProvider);
    final feedAsync = ref.watch(activeCorporateNewsProvider);

    return Column(
      children: [
        const _NewsFilters(),
        const Divider(height: 1, color: AppTheme.border),
        Expanded(
          child: feedAsync.when(
            data: (feed) => _NewsBody(feed: feed),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stackTrace) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(describeApiError(error), textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => ref.invalidate(corporateNewsProvider(query)),
                      child: const Text('Reintentar'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _NewsFilters extends ConsumerStatefulWidget {
  const _NewsFilters();

  @override
  ConsumerState<_NewsFilters> createState() => _NewsFiltersState();
}

class _NewsFiltersState extends ConsumerState<_NewsFilters> {
  final _tickerController = TextEditingController();

  @override
  void dispose() {
    _tickerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(newsQueryProvider);
    final controller = ref.read(newsQueryProvider.notifier);
    final feed = ref.watch(activeCorporateNewsProvider).valueOrNull;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 118,
                child: TextField(
                  controller: _tickerController,
                  textCapitalization: TextCapitalization.characters,
                  style: AppTheme.numeric(fontSize: 12),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Símbolo',
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  ),
                  onSubmitted: controller.setTicker,
                ),
              ),
              const SizedBox(width: 8),
              if (query.ticker != null)
                InputChip(
                  label: Text(query.ticker!, style: AppTheme.numeric(fontSize: 11)),
                  onDeleted: () {
                    _tickerController.clear();
                    controller.setTicker(null);
                  },
                ),
              const Spacer(),
              if (feed != null)
                Text(
                  // "3 de 20" y no "3": con tres filtros combinables, una lista corta es ambigua —
                  // puede ser todo lo que hay o el resultado de un filtro que quedó puesto.
                  feed.hasFilters
                      ? '${feed.total} de ${feed.totalBeforeFilters}'
                      : '${feed.total}',
                  style: AppTheme.numeric(fontSize: 11, color: AppTheme.textMuted),
                ),
              CachedIndicator(servedFromCache: feed?.servedFromCache ?? false),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Actualizar',
                onPressed: () => ref.invalidate(corporateNewsProvider(query)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final category in NewsCategory.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(
                        newsCategoryIcon(category),
                        size: 14,
                        color: newsCategoryColor(category),
                      ),
                      label: Text(
                        newsCategoryLabel(category),
                        style: const TextStyle(fontSize: 10.5),
                      ),
                      selected: query.category == category,
                      onSelected: (_) => controller.toggleCategory(category),
                    ),
                  ),
                const SizedBox(width: 6),
                const _FilterSeparator(),
                const SizedBox(width: 6),
                for (final sentiment in NewsSentiment.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(
                        newsSentimentLabel(sentiment),
                        style: TextStyle(
                          fontSize: 10.5,
                          color: newsSentimentColor(sentiment),
                        ),
                      ),
                      selected: query.sentiment == sentiment,
                      onSelected: (_) => controller.toggleSentiment(sentiment),
                    ),
                  ),
                if (query.hasFilters)
                  TextButton.icon(
                    onPressed: () {
                      _tickerController.clear();
                      controller.clearFilters();
                    },
                    icon: const Icon(Icons.filter_alt_off_outlined, size: 14),
                    label: const Text('Limpiar', style: TextStyle(fontSize: 11)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterSeparator extends StatelessWidget {
  const _FilterSeparator();

  @override
  Widget build(BuildContext context) => const SizedBox(
        height: 20,
        child: VerticalDivider(width: 1, color: AppTheme.border),
      );
}

class _NewsBody extends StatelessWidget {
  const _NewsBody({required this.feed});

  final CorporateNewsFeed feed;

  @override
  Widget build(BuildContext context) {
    final degraded = feed.availability == DataAvailability.unavailable;

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
      children: [
        if (degraded) ...[
          DegradationBanner(reason: feed.degradationReason),
          const SizedBox(height: 14),
        ],
        if (feed.items.isNotEmpty) ...[
          const _ClassificationNotice(),
          const SizedBox(height: 12),
        ],
        if (feed.items.isEmpty)
          _EmptyNews(feed: feed, degraded: degraded)
        else
          for (final item in feed.items)
            CorporateNewsCard(key: ValueKey(item.refId), item: item),
      ],
    );
  }
}

/// El cartel de procedencia del feed. Se muestra una vez arriba y no en cada fila: repetirlo veinte
/// veces lo volvería invisible, que es justo lo contrario de lo que se busca.
class _ClassificationNotice extends StatelessWidget {
  const _ClassificationNotice();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.label_outline, size: 14, color: AppTheme.textMuted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            classificationSourceCaption(ClassificationSource.keyword),
            style: const TextStyle(
                fontSize: 10.5, color: AppTheme.textMuted, height: 1.35),
          ),
        ),
      ],
    );
  }
}

/// Una noticia: titular, fuente, antigüedad, categoría y sentimiento.
///
/// Pública porque la Ficha del activo muestra las mismas tarjetas.
class CorporateNewsCard extends StatelessWidget {
  const CorporateNewsCard({super.key, required this.item});

  final CorporateNewsItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: AppTheme.panelDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              NewsCategoryBadge(category: item.category, dense: true),
              const SizedBox(width: 6),
              NewsSentimentBadge(
                sentiment: item.sentiment,
                source: item.classificationSource,
                dense: true,
              ),
              const Spacer(),
              _CopyNewsLinkButton(url: item.url),
              SaveToLabButton(
                heading: item.title,
                draft: newsNoteDraft(item),
                snippet: buildNewsNoteMarkdown(item),
                // La nota se vincula al símbolo de la noticia si trae alguno; una noticia de mercado
                // queda sin vincular en vez de atribuírsela a un activo al azar.
                ticker: item.tickers.isEmpty ? null : item.tickers.first,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            item.title,
            style: const TextStyle(
                fontSize: 13.5, fontWeight: FontWeight.w600, height: 1.35),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                // La fuente se muestra SIEMPRE: en un feed que mezcla rumores con hechos, es lo
                // único que permite pesarlos.
                item.source ?? 'fuente desconocida',
                style: AppTheme.numeric(fontSize: 10, color: AppTheme.textMuted),
              ),
              const Text(' · ',
                  style: TextStyle(fontSize: 10, color: AppTheme.textMuted)),
              Text(
                formatNewsAge(item.publishedAt),
                style: AppTheme.numeric(fontSize: 10, color: AppTheme.textMuted),
              ),
              if (item.tickers.isNotEmpty) ...[
                const Text(' · ',
                    style: TextStyle(fontSize: 10, color: AppTheme.textMuted)),
                Text(
                  item.tickers.join(' '),
                  style: AppTheme.numeric(fontSize: 10, color: AppTheme.accent),
                ),
              ],
            ],
          ),
          if (item.summary != null && item.summary!.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              item.summary!,
              style: const TextStyle(
                  fontSize: 12, color: AppTheme.textMuted, height: 1.45),
            ),
          ],
        ],
      ),
    );
  }
}

class _CopyNewsLinkButton extends StatelessWidget {
  const _CopyNewsLinkButton({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final target = url;
    if (target == null) return const SizedBox.shrink();

    return IconButton(
      icon: const Icon(Icons.link, size: 18),
      tooltip: 'Copiar el enlace de la noticia',
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: target));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enlace copiado al portapapeles.')),
        );
      },
    );
  }
}

class _EmptyNews extends ConsumerWidget {
  const _EmptyNews({required this.feed, required this.degraded});

  final CorporateNewsFeed feed;
  final bool degraded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Tres vacíos distintos, y se dicen distinto porque se arreglan distinto: el degradado se espera,
    // el filtrado se destraba sacando un filtro, y el genuinamente vacío no se arregla.
    final (message, action) = switch ((degraded, feed.emptiedByFilters)) {
      (true, _) => (
          'No se pudo traer el feed de noticias en este momento. '
              'El aviso de arriba dice por qué.',
          false,
        ),
      (false, true) => (
          'Ninguna de las ${feed.totalBeforeFilters} noticias del feed pasa los filtros puestos.',
          true,
        ),
      (false, false) => (
          'No hay noticias recientes para esta búsqueda.',
          false,
        ),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
      child: Column(
        children: [
          Icon(
            degraded ? Icons.cloud_off_outlined : Icons.newspaper_outlined,
            size: 34,
            color: AppTheme.textMuted,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textMuted, height: 1.45),
          ),
          if (action) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => ref.read(newsQueryProvider.notifier).clearFilters(),
              icon: const Icon(Icons.filter_alt_off_outlined, size: 16),
              label: const Text('Limpiar los filtros'),
            ),
          ],
        ],
      ),
    );
  }
}
