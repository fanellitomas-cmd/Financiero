import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../corporate/data/corporate_formatting.dart';
import '../data/portfolio_builder_models.dart';
import '../data/portfolio_formatting.dart';

/// Badge de concentración con su lectura.
///
/// El badge nunca va solo: "riesgo alto" sin decir de qué se lee como un juicio sobre los activos
/// elegidos, y lo que mide es el REPARTO. Por eso al lado va siempre qué sector domina y con cuánto.
class RiskBadge extends StatelessWidget {
  const RiskBadge({super.key, required this.result});

  final PortfolioSimulationResult result;

  @override
  Widget build(BuildContext context) {
    final level = result.riskScore;
    if (level == null) return const SizedBox.shrink();

    final color = riskColor(level);
    final topWeight = result.topSectorWeightPct;
    final topLabel = result.sectorAllocation.isEmpty
        ? null
        : result.sectorAllocation.first.label;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(riskIcon(level), size: 16, color: color),
              const SizedBox(width: 8),
              Text(
                'Concentración ${riskLevelLabel(level).toLowerCase()}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            riskCaption(level),
            style: const TextStyle(
              fontSize: 11.5,
              color: AppTheme.textMuted,
              height: 1.4,
            ),
          ),
          if (topLabel != null && topWeight != null) ...[
            const SizedBox(height: 6),
            Text(
              '$topLabel concentra ${formatWeightPct(topWeight)} del capital · '
              'Herfindahl ${formatHerfindahl(result.herfindahlIndex)}',
              style: AppTheme.numeric(fontSize: 10.5, color: AppTheme.textMuted),
            ),
          ],
          for (final note in result.riskNotes) ...[
            const SizedBox(height: 6),
            Text(
              '· $note',
              style: const TextStyle(
                fontSize: 10.5,
                color: AppTheme.textMuted,
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 8),
          const Text(
            // La provenance del veredicto: sin esto, "crítica" parece una opinión del modelo.
            'Nivel calculado en código con umbrales fijos sobre el peso del sector dominante y el '
            'índice de Herfindahl, tomando el peor de los dos. Misma escala que la Auditoría de '
            'Portafolio.',
            style: TextStyle(
              fontSize: 10,
              color: AppTheme.textMuted,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

/// Retorno histórico a 1 año, con su cobertura.
///
/// La cobertura no es un detalle técnico: un retorno medido sobre el 40% del capital describe una
/// parte de la cartera, y mostrarlo sin esa marca lo haría pasar por el retorno del total.
class ReturnCard extends StatelessWidget {
  const ReturnCard({super.key, required this.result});

  final PortfolioSimulationResult result;

  @override
  Widget build(BuildContext context) {
    final value = result.portfolioReturn1yPct;
    final complete = result.returnIsComplete;
    final color = value == null
        ? AppTheme.textMuted
        : (value > 0
            ? AppTheme.bullish
            : (value < 0 ? AppTheme.bearish : AppTheme.textMuted));

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history, size: 15, color: AppTheme.accent),
              const SizedBox(width: 8),
              Text(
                'Retorno del último año',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                formatSurprisePct(value),
                style: AppTheme.numeric(fontSize: 24, color: color)
                    .copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 8),
              if (value != null)
                const Text(
                  'ponderado por capital',
                  style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (value == null)
            const Text(
              'Ninguna posición tenía histórico suficiente para medir un año completo.',
              style: TextStyle(
                fontSize: 11,
                color: AppTheme.textMuted,
                height: 1.4,
              ),
            )
          else ...[
            _CoverageBar(coverage: result.returnCoveragePct),
            const SizedBox(height: 6),
            Text(
              complete
                  ? 'Medido sobre todo el capital asignado.'
                  : 'Medido sobre el ${formatWeightPct(result.returnCoveragePct)} del capital '
                      'asignado. El resto no tenía histórico y NO se contó como 0%.',
              style: TextStyle(
                fontSize: 10.5,
                color: complete ? AppTheme.textMuted : AppTheme.neutral,
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 8),
          const Text(
            'Es lo que pasó, no una proyección.',
            style: TextStyle(fontSize: 10, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }
}

class _CoverageBar extends StatelessWidget {
  const _CoverageBar({required this.coverage});

  final double coverage;

  @override
  Widget build(BuildContext context) {
    final fraction = (coverage / 100).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: LinearProgressIndicator(
        value: fraction,
        minHeight: 5,
        backgroundColor: AppTheme.surfaceSunken,
        valueColor: AlwaysStoppedAnimation<Color>(
          fraction >= 0.995 ? AppTheme.accent : AppTheme.neutral,
        ),
      ),
    );
  }
}
