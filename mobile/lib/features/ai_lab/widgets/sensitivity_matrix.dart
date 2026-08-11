import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../corporate/data/corporate_formatting.dart';
import '../data/ai_lab_models.dart';

/// La matriz Bear / Base / Bull.
///
/// El valor de la matriz no son los tres números sueltos: es **el ancho del rango**. Un escenario donde
/// el pesimista y el optimista difieren en 2 puntos de EPS y otro donde difieren en 40 se leen
/// distinto aunque el caso base sea idéntico, y eso es lo que la fila de abajo dice explícitamente.
///
/// Los tres casos se pintan con la escala de dirección (verde/rojo) sobre la VARIACIÓN, no sobre el
/// nombre del caso: un "bear" que igual da +12% de EPS no es una mala noticia, y pintarlo de rojo por
/// llamarse bear afirmaría lo contrario de lo que el número dice.
class SensitivityMatrix extends StatelessWidget {
  const SensitivityMatrix({super.key, required this.cases});

  final List<SensitivityCase> cases;

  @override
  Widget build(BuildContext context) {
    if (cases.isEmpty) return const SizedBox.shrink();

    final spread = _epsSpreadPp();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            // Tres columnas cuando entran con holgura; apiladas cuando no. Con menos de 380 px, tres
            // columnas dejarían los EPS en dos renglones cada uno y la comparación —que es todo el
            // punto de la matriz— se perdería.
            if (constraints.maxWidth < 380) {
              return Column(
                children: [
                  for (final item in cases) _CaseCard(item: item, stacked: true),
                ],
              );
            }
            // `IntrinsicHeight` es lo que iguala la altura de las tres tarjetas: sin él, `stretch`
            // le pasaría altura infinita a las tarjetas (la matriz vive dentro de una columna que
            // scrollea, así que arriba no hay altura acotada) y el layout revienta.
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final item in cases)
                    Expanded(child: _CaseCard(item: item, stacked: false)),
                ],
              ),
            );
          },
        ),
        if (spread != null) ...[
          const SizedBox(height: 8),
          Text(
            'Entre el pesimista y el optimista hay ${formatSurprisePct(spread).replaceAll("+", "")} '
            'de diferencia en el EPS: ${_spreadReading(spread)}',
            style: const TextStyle(
              fontSize: 11,
              color: AppTheme.textMuted,
              height: 1.4,
            ),
          ),
        ],
      ],
    );
  }

  /// La diferencia en puntos porcentuales entre el EPS del optimista y el del pesimista.
  ///
  /// Se mide sobre las VARIACIONES y no sobre los EPS absolutos: así el número es comparable entre
  /// empresas con EPS de 0,50 y de 40.
  double? _epsSpreadPp() {
    double? bear;
    double? bull;
    for (final item in cases) {
      if (item.scenarioCase == ScenarioCase.bear) {
        bear = item.projection.epsChangePct;
      }
      if (item.scenarioCase == ScenarioCase.bull) {
        bull = item.projection.epsChangePct;
      }
    }
    if (bear == null || bull == null) return null;
    return (bull - bear).abs();
  }

  String _spreadReading(double spreadPp) {
    // Los umbrales son del producto y están acá a la vista, con el número en el texto: sin eso,
    // "muy sensible" sería un juicio sin respaldo.
    if (spreadPp >= 30) {
      return 'el resultado es muy sensible a los supuestos.';
    }
    if (spreadPp >= 10) {
      return 'el resultado depende bastante de los supuestos.';
    }
    return 'el resultado es poco sensible a los supuestos.';
  }
}

class _CaseCard extends StatelessWidget {
  const _CaseCard({required this.item, required this.stacked});

  final SensitivityCase item;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final change = item.projection.epsChangePct;
    // El color sale del SIGNO de la variación, no del nombre del caso.
    final color = change == null
        ? AppTheme.textMuted
        : (change > 0
            ? AppTheme.bullish
            : (change < 0 ? AppTheme.bearish : AppTheme.accent));
    final isBase = item.scenarioCase == ScenarioCase.base;

    return Container(
      margin: stacked
          ? const EdgeInsets.only(bottom: 8)
          : const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
      decoration: BoxDecoration(
        color: isBase ? AppTheme.surface : AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(
          // El caso base se resalta porque es el que el usuario pidió: los otros dos son variaciones
          // que el sistema agregó, y confundirlos sería atribuirle supuestos que no eligió.
          color: isBase ? AppTheme.accent.withValues(alpha: 0.45) : AppTheme.border,
          width: isBase ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _caseTitle(item.scenarioCase),
            style: AppTheme.numeric(fontSize: 9.5, color: AppTheme.textMuted)
                .copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            formatEps(item.projection.eps),
            style: AppTheme.numeric(fontSize: 18, color: color)
                .copyWith(fontWeight: FontWeight.bold),
          ),
          Text(
            change == null ? kMissingValue : formatSurprisePct(change),
            style: AppTheme.numeric(fontSize: 11.5, color: color),
          ),
          const SizedBox(height: 6),
          Text(
            // La etiqueta que armó el backend dice qué se movió: un "bear" sin eso no es
            // reproducible ni discutible.
            item.label,
            style: const TextStyle(
              fontSize: 10,
              color: AppTheme.textMuted,
              height: 1.3,
            ),
          ),
          if (item.projection.impliedPrice != null) ...[
            const SizedBox(height: 6),
            Text(
              'Precio ${formatEps(item.projection.impliedPrice)}',
              style: AppTheme.numeric(fontSize: 10.5, color: AppTheme.textMuted),
            ),
          ],
        ],
      ),
    );
  }

  String _caseTitle(ScenarioCase kind) => switch (kind) {
        ScenarioCase.bear => 'PESIMISTA',
        ScenarioCase.base => 'BASE',
        ScenarioCase.bull => 'OPTIMISTA',
      };
}
