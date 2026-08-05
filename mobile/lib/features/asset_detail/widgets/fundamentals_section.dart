import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../data/deep_intelligence.dart';
import 'intelligence_common.dart';

/// Sección 1: ratios fundamentales y semáforo de salud financiera.
///
/// El semáforo lo calcula el BACKEND en código con umbrales explícitos, no el LLM: es
/// determinístico y reproducible. Acá solo se pinta, con las notas que lo sostienen — un semáforo
/// sin explicación no es auditable, y el usuario tiene derecho a ver por qué dice lo que dice.
class FundamentalsSection extends StatelessWidget {
  const FundamentalsSection({super.key, required this.fundamentals});

  final Fundamentals fundamentals;

  @override
  Widget build(BuildContext context) {
    final isUnavailable =
        fundamentals.availability == DataAvailability.unavailable;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IntelligenceSectionHeader(
              title: 'Fundamentales',
              subtitle: _subtitle(),
              availability: fundamentals.availability,
              trailing: isUnavailable
                  ? null
                  : FinancialHealthBadge(health: fundamentals.financialHealth),
            ),
            if (isUnavailable) ...[
              const SizedBox(height: 12),
              IntelligenceUnavailableBanner(
                reason: fundamentals.degradationReason,
                icon: Icons.query_stats,
              ),
              const SizedBox(height: 12),
              // La grilla se dibuja IGUAL con todo en "—": así el usuario ve qué ratios existen y
              // que faltan datos, en vez de una card vacía que no dice nada.
              _RatioGrid(ratios: fundamentals.ratios),
            ] else ...[
              const SizedBox(height: 14),
              _RatioGrid(ratios: fundamentals.ratios),
              if (fundamentals.financialHealthNotes.isNotEmpty) ...[
                const SizedBox(height: 14),
                const Divider(height: 1, color: AppTheme.border),
                const SizedBox(height: 12),
                Text(
                  'Por qué esta lectura',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: AppTheme.textMuted,
                      ),
                ),
                const SizedBox(height: 8),
                for (final note in fundamentals.financialHealthNotes)
                  IntelligenceBullet(
                    text: note,
                    bulletColor: _healthColor(fundamentals.financialHealth),
                  ),
              ],
              if (fundamentals.availability == DataAvailability.partial &&
                  fundamentals.degradationReason != null) ...[
                const SizedBox(height: 4),
                IntelligenceUnavailableBanner(
                  reason: fundamentals.degradationReason,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  String? _subtitle() {
    final parts = <String>[];
    if (fundamentals.period != null) parts.add(fundamentals.period!);
    if (fundamentals.ratios.isNotEmpty) {
      parts.add(
        '${fundamentals.availableCount} de ${fundamentals.ratios.length} ratios disponibles',
      );
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

Color _healthColor(FinancialHealth health) => switch (health) {
      FinancialHealth.solida => AppTheme.bullish,
      FinancialHealth.adecuada => AppTheme.bullish,
      FinancialHealth.ajustada => AppTheme.neutral,
      FinancialHealth.debil => AppTheme.bearish,
      FinancialHealth.indeterminada => AppTheme.textMuted,
    };

/// Badge de salud financiera con código de color: verde sólida/adecuada, ámbar ajustada, rojo débil.
///
/// `INDETERMINADA` va en gris y no en ámbar: el backend la devuelve cuando no hay al menos tres
/// señales, así que no es un diagnóstico intermedio sino la ausencia de diagnóstico. Pintarla de
/// ámbar la haría leer como "hay algo de riesgo", que sería afirmar más de lo que se sabe.
class FinancialHealthBadge extends StatelessWidget {
  const FinancialHealthBadge({super.key, required this.health});

  final FinancialHealth health;

  @override
  Widget build(BuildContext context) {
    final (label, icon) = switch (health) {
      FinancialHealth.solida => ('SÓLIDA', Icons.verified_outlined),
      FinancialHealth.adecuada => ('ADECUADA', Icons.check_circle_outline),
      FinancialHealth.ajustada => ('AJUSTADA', Icons.warning_amber_outlined),
      FinancialHealth.debil => ('DÉBIL', Icons.error_outline),
      FinancialHealth.indeterminada => (
          'SIN DIAGNÓSTICO',
          Icons.help_outline,
        ),
    };
    final color = _healthColor(health);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: AppTheme.badgeDecoration(color),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: AppTheme.numeric(
              fontSize: 10,
              color: color,
            ).copyWith(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

/// Grilla de ratios. El ancho de columna se decide por el ancho REAL disponible, no por el de la
/// ventana: en master-detail esta grilla vive en el panel derecho, y mirar `MediaQuery` daría
/// demasiadas columnas cuando el panel es angosto.
class _RatioGrid extends StatelessWidget {
  const _RatioGrid({required this.ratios});

  final List<RatioValue> ratios;

  @override
  Widget build(BuildContext context) {
    if (ratios.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        const targetCellWidth = 150.0;
        final columns =
            (constraints.maxWidth / targetCellWidth).floor().clamp(2, 4);
        // Alto fijo por celda en vez de `childAspectRatio`: la etiqueta y el valor ocupan lo mismo
        // en toda la grilla, y con un ratio la celda cambiaría de alto según el ancho disponible.
        final cellWidth = constraints.maxWidth / columns;

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: cellWidth / 58,
          ),
          itemCount: ratios.length,
          itemBuilder: (context, index) => _RatioCell(ratio: ratios[index]),
        );
      },
    );
  }
}

class _RatioCell extends StatelessWidget {
  const _RatioCell({required this.ratio});

  final RatioValue ratio;

  @override
  Widget build(BuildContext context) {
    final available = ratio.isAvailable;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            ratio.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
          ),
          const SizedBox(height: 3),
          Text(
            ratio.formatted,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.numeric(
              fontSize: 14,
              // Un ratio ausente va en gris apagado: el "—" no debe competir visualmente con los
              // valores reales de al lado.
              color: available ? null : AppTheme.textMuted,
            ).copyWith(fontWeight: available ? FontWeight.bold : null),
          ),
        ],
      ),
    );
  }
}
