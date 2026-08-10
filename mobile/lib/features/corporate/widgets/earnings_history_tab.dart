import 'package:flutter/material.dart';
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
import 'surprise_chart.dart';

/// Pestaña "Histórico": qué tan seguido esta empresa le pega a la estimación.
///
/// La tasa de aciertos se presenta SIEMPRE con su denominador ("3 de 4 medidos") y nunca como un
/// porcentaje suelto: los trimestres sin estimación previa no entran, y un "75%" sin el denominador
/// esconde que la muestra puede ser de cuatro trimestres.
class EarningsHistoryTab extends ConsumerWidget {
  const EarningsHistoryTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ticker = ref.watch(corporateTickerProvider);

    if (ticker == null || ticker.isEmpty) {
      return const _NeedsTicker(
        icon: Icons.history_outlined,
        message: 'Elegí un símbolo arriba para ver su histórico de sorpresas: '
            'cuántas veces superó la estimación de EPS y por cuánto.',
      );
    }

    final query = HistoryQuery(ticker: ticker);
    final historyAsync = ref.watch(earningsHistoryProvider(query));

    return historyAsync.when(
      data: (history) => _HistoryBody(history: history),
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
                onPressed: () => ref.invalidate(earningsHistoryProvider(query)),
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryBody extends StatelessWidget {
  const _HistoryBody({required this.history});

  final EarningsHistory history;

  @override
  Widget build(BuildContext context) {
    final degraded = history.availability == DataAvailability.unavailable;

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Sorpresas de ${history.ticker}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            CachedIndicator(servedFromCache: history.servedFromCache),
            if (history.quarters.isNotEmpty)
              SaveToLabButton(
                heading: 'Histórico de sorpresas de ${history.ticker}',
                draft: earningsHistoryNoteDraft(history),
                snippet: buildEarningsHistoryNoteMarkdown(history),
                ticker: history.ticker,
                tooltip: 'Guardar el histórico en el Investment Lab',
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (degraded) ...[
          DegradationBanner(reason: history.degradationReason),
          const SizedBox(height: 14),
        ],
        if (history.quarters.isEmpty)
          _EmptyHistory(ticker: history.ticker, degraded: degraded)
        else ...[
          _HistoryStats(history: history),
          const SizedBox(height: 16),
          SurpriseChart(quarters: history.quarters),
          const SizedBox(height: 18),
          Text(
            'Trimestres publicados',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          for (final quarter in history.quarters) _QuarterRow(quarter: quarter),
        ],
      ],
    );
  }
}

/// Los agregados: aciertos, fallos, en línea y sorpresa promedio.
class _HistoryStats extends StatelessWidget {
  const _HistoryStats({required this.history});

  final EarningsHistory history;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.panelDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 22,
            runSpacing: 12,
            children: [
              _StatTile(
                label: 'Superó',
                // El denominador viaja PEGADO al número, no en una nota al pie: "3" solo no dice
                // nada y "75%" solo esconde que la muestra son cuatro trimestres.
                value: '${history.beatCount}/${history.measuredQuarters}',
                caption: history.beatRate == null
                    ? 'sin trimestres medidos'
                    : '${formatRate(history.beatRate)} de aciertos',
                color: AppTheme.bullish,
              ),
              _StatTile(
                label: 'Falló',
                value: '${history.missCount}',
                color: AppTheme.bearish,
              ),
              _StatTile(
                label: 'En línea',
                value: '${history.inLineCount}',
                color: AppTheme.accent,
              ),
              _StatTile(
                label: 'Sorpresa prom.',
                value: formatSurprisePct(history.averageSurprisePct),
                caption: history.averageSurprisePct == null
                    ? 'ningún trimestre con % calculable'
                    : 'sobre los % calculables',
                color: history.averageSurprisePct == null
                    ? AppTheme.textMuted
                    : (history.averageSurprisePct! >= 0
                        ? AppTheme.bullish
                        : AppTheme.bearish),
              ),
            ],
          ),
          if (history.unmeasuredQuarters > 0) ...[
            const SizedBox(height: 12),
            Text(
              // Explica por qué la lista de abajo tiene más filas que el denominador de arriba. Sin
              // esto, "3 de 4" sobre una lista de seis trimestres parece un error de la app.
              '${history.unmeasuredQuarters} trimestre(s) llegaron sin estimación previa: no se '
              'pueden contar ni como acierto ni como fallo, así que quedan fuera de la tasa.',
              style: const TextStyle(fontSize: 11, color: AppTheme.textMuted, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.color,
    this.caption,
  });

  final String label;
  final String value;
  final Color color;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textMuted)),
        const SizedBox(height: 2),
        Text(
          value,
          style: AppTheme.numeric(fontSize: 19, color: color)
              .copyWith(fontWeight: FontWeight.bold),
        ),
        if (caption != null)
          Text(
            caption!,
            style: const TextStyle(fontSize: 9.5, color: AppTheme.textMuted),
          ),
      ],
    );
  }
}

class _QuarterRow extends StatelessWidget {
  const _QuarterRow({required this.quarter});

  final EarningsEvent quarter;

  @override
  Widget build(BuildContext context) {
    final period = formatFiscalPeriod(quarter);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: AppTheme.panelDecoration,
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                formatCorporateDate(quarter.eventDate),
                style: AppTheme.numeric(fontSize: 12.5)
                    .copyWith(fontWeight: FontWeight.w600),
              ),
              if (period != null)
                Text(
                  period,
                  style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
                ),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                _MiniMetric(label: 'est.', value: formatEps(quarter.epsEstimated)),
                _MiniMetric(
                  label: 'rep.',
                  value: formatEps(quarter.epsActual),
                  color: surpriseDirectionColor(quarter.surpriseDirection),
                ),
                _MiniMetric(
                  label: 'dif.',
                  value: formatEpsDelta(quarter.epsSurprise),
                  color: surpriseDirectionColor(quarter.surpriseDirection),
                ),
              ],
            ),
          ),
          SurpriseBadge(
            direction: quarter.surpriseDirection,
            surprisePct: quarter.epsSurprisePct == null
                ? null
                : formatSurprisePct(quarter.epsSurprisePct),
            dense: true,
          ),
          SaveToLabButton(
            heading: 'Balance de ${quarter.ticker} del '
                '${formatCorporateDate(quarter.eventDate)}',
            draft: earningsNoteDraft(quarter),
            snippet: buildEarningsNoteMarkdown(quarter),
            ticker: quarter.ticker,
          ),
        ],
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label, style: const TextStyle(fontSize: 9.5, color: AppTheme.textMuted)),
        const SizedBox(width: 4),
        Text(value, style: AppTheme.numeric(fontSize: 12, color: color)),
      ],
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory({required this.ticker, required this.degraded});

  final String ticker;
  final bool degraded;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      child: Column(
        children: [
          Icon(
            degraded ? Icons.cloud_off_outlined : Icons.history_toggle_off_outlined,
            size: 34,
            color: AppTheme.textMuted,
          ),
          const SizedBox(height: 12),
          Text(
            degraded
                ? 'No se pudo traer el histórico de $ticker en este momento.'
                : 'El proveedor no tiene trimestres publicados de $ticker.\n'
                    'Puede ser una empresa que recién cotiza, o un símbolo que no reporta ante la SEC.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textMuted, height: 1.45),
          ),
        ],
      ),
    );
  }
}

/// Placeholder de las pestañas que necesitan un símbolo elegido.
class _NeedsTicker extends StatelessWidget {
  const _NeedsTicker({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: AppTheme.textMuted),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textMuted, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}

/// Se expone para que la pestaña de reportes muestre el mismo placeholder: las dos dependen del
/// mismo símbolo elegido, y dos textos distintos harían creer que son dos selectores distintos.
class NeedsTickerPlaceholder extends StatelessWidget {
  const NeedsTickerPlaceholder({
    super.key,
    required this.icon,
    required this.message,
  });

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => _NeedsTicker(icon: icon, message: message);
}
