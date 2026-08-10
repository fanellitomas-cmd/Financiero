import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../ai/presentation/financial_translator_controller.dart';
import '../../ai/widgets/financial_translation_card.dart';
import '../data/deep_intelligence.dart';
import 'intelligence_common.dart';

/// Sección 2: síntesis de reportes oficiales y noticias, con pestañas de fuentes.
///
/// Los puntos clave y los riesgos van SEPARADOS, no en una sola lista: un resumen que los mezcla
/// deja al lector armando el balance a mano, que es justo el trabajo que la Ficha tiene que hacer
/// por él. Los puntos van en emerald y los riesgos en coral, así el balance se lee sin leer.
///
/// Las pestañas de fuentes separan reportes oficiales (10-K/10-Q, transcripciones) de noticias
/// porque tienen peso probatorio distinto: un filing es lo que la empresa afirmó formalmente, una
/// nota de prensa es lo que alguien reportó.
class RagSummarySection extends ConsumerStatefulWidget {
  const RagSummarySection({
    super.key,
    required this.summary,
    required this.ticker,
  });

  final RagSummary summary;
  final String ticker;

  @override
  ConsumerState<RagSummarySection> createState() => _RagSummarySectionState();
}

class _RagSummarySectionState extends ConsumerState<RagSummarySection> {
  bool _showFilings = true;

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    final isUnavailable = summary.availability == DataAvailability.unavailable;
    final beginnerMode = ref.watch(beginnerModeProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IntelligenceSectionHeader(
              title: 'Investigación sobre reportes',
              subtitle: isUnavailable
                  ? null
                  : '${summary.sources.length} '
                      '${summary.sources.length == 1 ? "fuente" : "fuentes"} citadas',
              availability: summary.availability,
            ),
            if (isUnavailable) ...[
              const SizedBox(height: 12),
              DegradationBanner(
                reason: summary.degradationReason,
                icon: Icons.menu_book_outlined,
              ),
            ] else ...[
              if (summary.headline != null) ...[
                const SizedBox(height: 12),
                Text(
                  summary.headline!,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
              if (summary.keyPoints.isNotEmpty) ...[
                const SizedBox(height: 14),
                const _SubHeader(
                  label: 'Puntos clave',
                  icon: Icons.trending_up,
                  color: AppTheme.bullish,
                ),
                const SizedBox(height: 8),
                for (final point in summary.keyPoints)
                  IntelligenceBullet(
                    text: point,
                    bulletColor: AppTheme.bullish,
                  ),
              ],
              if (summary.risks.isNotEmpty) ...[
                const SizedBox(height: 8),
                const _SubHeader(
                  label: 'Riesgos',
                  icon: Icons.warning_amber_outlined,
                  color: AppTheme.bearish,
                ),
                const SizedBox(height: 8),
                for (final risk in summary.risks)
                  IntelligenceBullet(text: risk, bulletColor: AppTheme.bearish),
              ],
              if (summary.sources.isNotEmpty) ...[
                const SizedBox(height: 6),
                const Divider(height: 1, color: AppTheme.border),
                const SizedBox(height: 12),
                _SourceTabs(
                  filingCount: summary.filings.length,
                  newsCount: summary.news.length,
                  showFilings: _showFilings,
                  onChanged: (value) => setState(() => _showFilings = value),
                ),
                const SizedBox(height: 10),
                _SourceList(
                  sources: _showFilings ? summary.filings : summary.news,
                  emptyMessage: _showFilings
                      ? 'No se citaron reportes oficiales en este análisis.'
                      : 'No se citaron noticias en este análisis.',
                ),
              ],
              if (beginnerMode)
                if (_translatableText(summary) case final text?)
                  FinancialTranslationCard(
                    text: text,
                    context: '${widget.ticker} · síntesis de reportes',
                  ),
            ],
          ],
        ),
      ),
    );
  }

  /// El titular más los puntos clave y los riesgos: es la síntesis en sí, que es el texto más
  /// cargado de jerga de toda la Ficha (viene redactado por el modelo sobre reportes contables).
  ///
  /// Las fuentes NO entran: son títulos y fechas, no hay nada que traducir ahí.
  String? _translatableText(RagSummary summary) {
    final parts = [
      if (summary.headline != null) summary.headline!,
      ...summary.keyPoints,
      if (summary.risks.isNotEmpty) 'Riesgos: ${summary.risks.join(' ')}',
    ];
    return parts.isEmpty ? null : parts.join(' ');
  }
}

class _SubHeader extends StatelessWidget {
  const _SubHeader({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }
}

/// Selector SEC / Noticias. `SegmentedButton` y no `TabBar`: un `TabBar` necesita un
/// `TabController` y un `TabBarView` de alto acotado, y acá las dos listas viven dentro de una card
/// que crece con su contenido — un alto fijo dejaría la lista corta con hueco y la larga con scroll
/// anidado.
class _SourceTabs extends StatelessWidget {
  const _SourceTabs({
    required this.filingCount,
    required this.newsCount,
    required this.showFilings,
    required this.onChanged,
  });

  final int filingCount;
  final int newsCount;
  final bool showFilings;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<bool>(
        style: const ButtonStyle(
          visualDensity: VisualDensity(horizontal: -2, vertical: -2),
        ),
        segments: [
          ButtonSegment(
            value: true,
            label: Text('SEC ($filingCount)'),
            icon: const Icon(Icons.description_outlined, size: 14),
          ),
          ButtonSegment(
            value: false,
            label: Text('Noticias ($newsCount)'),
            icon: const Icon(Icons.newspaper_outlined, size: 14),
          ),
        ],
        selected: {showFilings},
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}

class _SourceList extends StatelessWidget {
  const _SourceList({required this.sources, required this.emptyMessage});

  final List<SourceReference> sources;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) {
      return Text(
        emptyMessage,
        style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final source in sources) _SourceRow(source: source),
      ],
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.source});

  final SourceReference source;

  @override
  Widget build(BuildContext context) {
    final published = source.publishedAt;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SourceRefChip(refId: source.refId, tooltip: source.sourceType),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  source.title ?? source.sourceType,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, height: 1.35),
                ),
                if (published != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    // Fecha en monoespaciada: en una lista de fuentes, las fechas alineadas se
                    // comparan de un vistazo.
                    '${published.day.toString().padLeft(2, '0')}/'
                    '${published.month.toString().padLeft(2, '0')}/'
                    '${published.year}',
                    style: AppTheme.numeric(
                      fontSize: 10,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
