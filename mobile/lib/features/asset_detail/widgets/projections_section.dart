import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../ai/presentation/financial_translator_controller.dart';
import '../../ai/widgets/financial_translation_card.dart';
import '../data/deep_intelligence.dart';
import 'intelligence_common.dart';

/// Sección 3: las tres proyecciones por horizonte.
///
/// Cada tarjeta tiene un diseño DISTINTO porque cada horizonte responde una pregunta distinta, y
/// darles la misma forma sugeriría que dicen lo mismo a distinta escala:
///   - Corto: una flecha de dirección y un medidor de confianza. Es una señal, se lee en un segundo.
///   - Mediano: tres escenarios con barras de probabilidad y una lista de catalizadores. Es un
///     abanico, se compara.
///   - Largo: una tesis en prosa, con lo que la sostiene y lo que la invalidaría. Es un argumento,
///     se lee entero.
class ProjectionsSection extends ConsumerWidget {
  const ProjectionsSection({
    super.key,
    required this.projections,
    required this.ticker,
  });

  final Projections projections;
  final String ticker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isUnavailable =
        projections.availability == DataAvailability.unavailable;
    final beginnerMode = ref.watch(beginnerModeProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: IntelligenceSectionHeader(
            title: 'Proyecciones por horizonte',
            availability: projections.availability,
          ),
        ),
        const SizedBox(height: 10),
        if (isUnavailable || !projections.hasAny)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: DegradationBanner(
                reason: projections.degradationReason,
                icon: Icons.timeline_outlined,
              ),
            ),
          )
        else ...[
          // Cada horizonte es opcional por separado: el modelo puede tener base para el corto y no
          // para el largo. Se muestra lo que hay, sin dejar huecos que parezcan un error.
          if (projections.shortTerm case final short?)
            _ShortTermCard(projection: short),
          if (projections.mediumTerm case final medium?) ...[
            const SizedBox(height: 12),
            _MediumTermCard(projection: medium),
          ],
          if (projections.longTerm case final long?) ...[
            const SizedBox(height: 12),
            _LongTermCard(projection: long),
          ],
          if (beginnerMode)
            if (_translatableText() case final text?)
              FinancialTranslationCard(
                text: text,
                context: '$ticker · proyecciones',
              ),
        ],
      ],
    );
  }

  /// La tesis de largo plazo más el argumento de corto: son los dos textos en prosa de la sección,
  /// y los que traen el vocabulario que hay que desarmar ("compresión de múltiplos", "guidance",
  /// "convicción").
  ///
  /// Las probabilidades de los escenarios NO entran: un porcentaje no necesita traducción, y
  /// mandarlos diluiría la explicación de lo que sí la necesita.
  String? _translatableText() {
    final parts = [
      if (projections.longTerm case final long?) long.thesis,
      if (projections.shortTerm case final short?) short.argument,
    ];
    return parts.isEmpty ? null : parts.join(' ');
  }
}

/// Cabecera común de las tres tarjetas: la banda de color de la izquierda es lo que las hace
/// distinguibles de un vistazo al hacer scroll.
class _HorizonCardShell extends StatelessWidget {
  const _HorizonCardShell({
    required this.label,
    required this.accent,
    required this.icon,
    required this.trailing,
    required this.child,
  });

  final String label;
  final Color accent;
  final IconData icon;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      // La banda de color es un BORDE IZQUIERDO del contenedor interno, no una `Row` con un
      // `Container` de 3px estirado: un `Row` con `CrossAxisAlignment.stretch` dentro de un
      // `ListView` recibe alto infinito y revienta el layout, y resolverlo con `IntrinsicHeight`
      // costaría una pasada extra de medición por card. Un borde es un solo render object.
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: accent, width: 3)),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 15, color: accent),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: accent,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

// --- Corto plazo: dirección + confianza ----------------------------------------------------

class _ShortTermCard extends StatelessWidget {
  const _ShortTermCard({required this.projection});

  final ShortTermProjection projection;

  @override
  Widget build(BuildContext context) {
    final (trendLabel, trendColor, trendIcon) = switch (projection.trend) {
      TrendDirection.alcista => (
          'ALCISTA',
          AppTheme.bullish,
          Icons.arrow_upward,
        ),
      TrendDirection.bajista => (
          'BAJISTA',
          AppTheme.bearish,
          Icons.arrow_downward,
        ),
      // Lateral en ámbar y no en gris: es una lectura del mercado, no un dato ausente.
      TrendDirection.lateral => (
          'LATERAL',
          AppTheme.neutral,
          Icons.arrow_forward,
        ),
    };

    return _HorizonCardShell(
      label: projection.horizonLabel.toUpperCase(),
      accent: AppTheme.accent,
      icon: Icons.bolt_outlined,
      trailing: _ConfidenceMeter(confidence: projection.confidence),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: AppTheme.badgeDecoration(trendColor),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(trendIcon, size: 14, color: trendColor),
                    const SizedBox(width: 6),
                    Text(
                      trendLabel,
                      style: AppTheme.numeric(
                        fontSize: 11,
                        color: trendColor,
                      ).copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            projection.argument,
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
          if (projection.evidenceRefs.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                for (final ref in projection.evidenceRefs)
                  SourceRefChip(refId: ref),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Confianza como tres barritas llenas/vacías. Es más rápido de leer que la palabra "MEDIA" y no
/// necesita que el usuario recuerde la escala.
class _ConfidenceMeter extends StatelessWidget {
  const _ConfidenceMeter({required this.confidence});

  final ConfidenceLevel confidence;

  @override
  Widget build(BuildContext context) {
    final filled = switch (confidence) {
      ConfidenceLevel.alta => 3,
      ConfidenceLevel.media => 2,
      ConfidenceLevel.baja => 1,
    };
    final color = switch (confidence) {
      ConfidenceLevel.alta => AppTheme.bullish,
      ConfidenceLevel.media => AppTheme.neutral,
      ConfidenceLevel.baja => AppTheme.textMuted,
    };

    return Tooltip(
      message: 'Confianza: ${confidence.name}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Confianza',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 10),
          ),
          const SizedBox(width: 6),
          for (var index = 0; index < 3; index++)
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Container(
                width: 4,
                height: 11,
                decoration: BoxDecoration(
                  color: index < filled ? color : color.withValues(alpha: 0.20),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// --- Mediano plazo: escenarios + catalizadores ----------------------------------------------

class _MediumTermCard extends StatelessWidget {
  const _MediumTermCard({required this.projection});

  final MediumTermProjection projection;

  @override
  Widget build(BuildContext context) {
    return _HorizonCardShell(
      label: projection.horizonLabel.toUpperCase(),
      accent: AppTheme.neutral,
      icon: Icons.alt_route_outlined,
      trailing: _ConfidenceMeter(confidence: projection.confidence),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final scenario in projection.scenarios)
            _ScenarioRow(scenario: scenario),
          if (projection.catalysts.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Divider(height: 1, color: AppTheme.border),
            const SizedBox(height: 10),
            const Row(
              children: [
                Icon(
                  Icons.event_outlined,
                  size: 13,
                  color: AppTheme.textMuted,
                ),
                SizedBox(width: 6),
                Text(
                  'Catalizadores',
                  style: TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final catalyst in projection.catalysts)
              IntelligenceBullet(text: catalyst),
          ],
        ],
      ),
    );
  }
}

class _ScenarioRow extends StatelessWidget {
  const _ScenarioRow({required this.scenario});

  final ScenarioOutlook scenario;

  @override
  Widget build(BuildContext context) {
    final color = switch (scenario.label.toUpperCase()) {
      'ALCISTA' => AppTheme.bullish,
      'BAJISTA' => AppTheme.bearish,
      // El caso base va en cian: no es una dirección de mercado, es el escenario de referencia.
      _ => AppTheme.accent,
    };
    final probability = scenario.probabilityPct;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  scenario.label.toUpperCase(),
                  style: AppTheme.numeric(
                    fontSize: 10,
                    color: color,
                  ).copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              Text(
                // Sin probabilidad se muestra "s/d" y no un 0%: el modelo puede no tener base para
                // cuantificar, y un 0 se leería como "escenario descartado".
                probability == null
                    ? 's/d'
                    : '${probability.toStringAsFixed(0)}%',
                style: AppTheme.numeric(
                  fontSize: 12,
                  color: probability == null ? AppTheme.textMuted : color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          if (probability != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: (probability / 100).clamp(0.0, 1.0),
                color: color,
                backgroundColor: AppTheme.surfaceSunken,
                minHeight: 5,
              ),
            ),
          const SizedBox(height: 6),
          Text(
            scenario.narrative,
            style: const TextStyle(fontSize: 12.5, height: 1.4),
          ),
        ],
      ),
    );
  }
}

// --- Largo plazo: tesis + invalidación -----------------------------------------------------

class _LongTermCard extends StatelessWidget {
  const _LongTermCard({required this.projection});

  final LongTermProjection projection;

  @override
  Widget build(BuildContext context) {
    return _HorizonCardShell(
      label: projection.horizonLabel.toUpperCase(),
      accent: AppTheme.bullish,
      icon: Icons.account_balance_outlined,
      trailing: _ConvictionBadge(conviction: projection.conviction),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // La tesis en cursiva y sobre superficie hundida: es la única prosa de argumentación de
          // toda la Ficha, y separarla visualmente invita a leerla en vez de barrerla.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: AppTheme.surfaceSunken,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.border),
            ),
            child: Text(
              projection.thesis,
              style: const TextStyle(
                fontSize: 13,
                height: 1.45,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          if (projection.supportingFactors.isNotEmpty) ...[
            const SizedBox(height: 12),
            _FactorList(
              label: 'Lo que la sostiene',
              icon: Icons.check_circle_outline,
              color: AppTheme.bullish,
              items: projection.supportingFactors,
            ),
          ],
          if (projection.invalidationTriggers.isNotEmpty) ...[
            const SizedBox(height: 10),
            // Los desencadenantes de invalidación son lo que distingue una tesis de una expresión
            // de deseo, así que van con el mismo peso visual que los factores de apoyo — no como
            // una nota al pie.
            _FactorList(
              label: 'Qué la invalidaría',
              icon: Icons.cancel_outlined,
              color: AppTheme.bearish,
              items: projection.invalidationTriggers,
            ),
          ],
          if (projection.evidenceRefs.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                for (final ref in projection.evidenceRefs)
                  SourceRefChip(refId: ref),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _FactorList extends StatelessWidget {
  const _FactorList({
    required this.label,
    required this.icon,
    required this.color,
    required this.items,
  });

  final String label;
  final IconData icon;
  final Color color;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final item in items)
          IntelligenceBullet(text: item, bulletColor: color),
      ],
    );
  }
}

class _ConvictionBadge extends StatelessWidget {
  const _ConvictionBadge({required this.conviction});

  final ConvictionLevel conviction;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (conviction) {
      ConvictionLevel.alta => ('CONVICCIÓN ALTA', AppTheme.bullish),
      ConvictionLevel.moderada => ('CONVICCIÓN MODERADA', AppTheme.neutral),
      ConvictionLevel.baja => ('CONVICCIÓN BAJA', AppTheme.textMuted),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: AppTheme.badgeDecoration(color),
      child: Text(
        label,
        style: AppTheme.numeric(
          fontSize: 9,
          color: color,
        ).copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}
