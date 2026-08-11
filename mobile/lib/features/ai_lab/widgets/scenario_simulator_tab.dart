import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/degradation_banner.dart';
import '../../corporate/data/corporate_formatting.dart';
import '../../corporate/widgets/save_to_lab_sheet.dart';
import '../data/ai_lab_models.dart';
import '../data/ai_lab_note_snippet.dart';
import '../presentation/ai_lab_controller.dart';
import 'analysis_blocks.dart';
import 'scenario_levers.dart';
import 'sensitivity_matrix.dart';

/// Pestaña "Simulador": las cuatro palancas, el evento en texto y el resultado.
///
/// La simulación se dispara con un BOTÓN y no al mover un slider. Dos razones y las dos importan: cada
/// corrida cuesta una llamada al modelo, y un resultado que cambia mientras se arrastra el dedo invita
/// a leerlo como una respuesta en vivo del mercado en vez de como el cálculo de un escenario.
class ScenarioSimulatorTab extends ConsumerWidget {
  const ScenarioSimulatorTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ticker = ref.watch(aiLabTickerProvider);

    if (ticker == null || ticker.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.tune_outlined, size: 36, color: AppTheme.textMuted),
              SizedBox(height: 14),
              Text(
                'Elegí una empresa arriba para simular escenarios sobre sus estados contables: '
                'crecimiento, margen, tasa de interés e inflación.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textMuted, height: 1.45),
              ),
            ],
          ),
        ),
      );
    }

    final panel = <Widget>[
      const _LeverPanel(),
      const SizedBox(height: 12),
      const _EventField(),
      const SizedBox(height: 12),
      const _RunButton(),
    ];

    final results = <Widget>[const _SimulationResults()];

    if (context.isDesktop) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: panel,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: results,
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [...panel, const SizedBox(height: 18), ...results],
    );
  }
}

/// Las cuatro palancas.
class _LeverPanel extends ConsumerWidget {
  const _LeverPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final variables = ref.watch(scenarioVariablesProvider);
    final controller = ref.read(scenarioVariablesProvider.notifier);
    final running = ref.watch(simulationControllerProvider).isRunning;

    // La base del último balance, si ya hay una simulación o un diagnóstico cargados: sirve para que
    // el margen y la tasa arranquen en el número REAL de la empresa en vez de en un default genérico.
    final baseline = ref.watch(simulationControllerProvider).result?.baseline;
    final analysisIncome =
        ref.watch(analysisControllerProvider).analysis?.latestIncome;
    final baselineMargin =
        baseline?.ebitdaMarginPct ?? analysisIncome?.ebitdaMarginPct;
    final impliedRate = baseline?.impliedInterestRatePct;

    return AnalysisCard(
      title: 'Palancas del escenario',
      icon: Icons.tune_outlined,
      subtitle: 'Cada palanca apagada deja ese supuesto como está en el balance',
      trailing: variables.isEmpty
          ? null
          : TextButton.icon(
              onPressed: running ? null : controller.reset,
              icon: const Icon(Icons.restart_alt, size: 15),
              label: const Text('Limpiar', style: TextStyle(fontSize: 11)),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScenarioLever(
            label: 'Crecimiento de ingresos',
            helper: 'Apagada, los ingresos se proyectan planos respecto del último período.',
            value: variables.revenueGrowthPct,
            min: -50,
            max: 100,
            divisions: 150,
            enabled: !running,
            onChanged: controller.setGrowth,
            onActivate: () => controller.setGrowth(
              ScenarioVariablesController.defaultGrowthPct,
            ),
          ),
          ScenarioLever(
            label: 'Margen EBITDA',
            // La explicación no es cosmética: es la diferencia entre "sin fijar" y "en cero", que en
            // esta palanca cambia el escenario entero.
            helper: 'Apagada, se parte del margen del balance y la inflación le resta los puntos '
                'que no se traspasan a precios.',
            baselineLabel: baselineMargin == null
                ? null
                : 'Margen del balance: '
                    '${baselineMargin.toStringAsFixed(1).replaceAll('.', ',')}%',
            value: variables.ebitdaMarginPct,
            // Es un NIVEL, no una variación: "63,9%" es el margen al que queda congelada la
            // proyección, y un "+" adelante lo convertiría en "63,9 puntos más de margen".
            signed: false,
            min: 0,
            max: 90,
            divisions: 90,
            enabled: !running,
            onChanged: controller.setMargin,
            onActivate: () =>
                controller.activateMargin(baselineMarginPct: baselineMargin),
          ),
          ScenarioLever(
            label: 'Tasa de interés',
            helper: 'Apagada, el gasto de intereses queda igual al del último balance.',
            baselineLabel: impliedRate == null
                ? null
                : 'Tasa implícita del balance: '
                    '${impliedRate.toStringAsFixed(2).replaceAll('.', ',')}%',
            value: variables.interestRatePct,
            // Ídem: es la tasa a la que se recalculan los intereses, no cuánto sube la tasa.
            signed: false,
            min: 0,
            max: 30,
            divisions: 120,
            enabled: !running,
            onChanged: controller.setInterest,
            onActivate: () =>
                controller.activateInterest(impliedRatePct: impliedRate),
          ),
          ScenarioLever(
            label: 'Inflación',
            helper: 'Apagada, no se le descuenta nada al margen por inflación de costos.',
            value: variables.inflationPct,
            min: 0,
            max: 100,
            divisions: 200,
            enabled: !running,
            onChanged: controller.setInflation,
            onActivate: () => controller.setInflation(
              ScenarioVariablesController.defaultInflationPct,
            ),
          ),
        ],
      ),
    );
  }
}

/// El evento o rumor en lenguaje natural.
///
/// Lleva la advertencia pegada arriba del campo y no en un tooltip: alguien que escribe "pierden el
/// juicio antimonopolio" y después ve un EPS proyectado tiene que saber, ANTES de escribir, que ese
/// EPS no incluye el juicio.
class _EventField extends ConsumerStatefulWidget {
  const _EventField();

  @override
  ConsumerState<_EventField> createState() => _EventFieldState();
}

class _EventFieldState extends ConsumerState<_EventField> {
  late final TextEditingController _controller = TextEditingController(
    text: ref.read(scenarioVariablesProvider).customEvent ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final running = ref.watch(simulationControllerProvider).isRunning;

    return AnalysisCard(
      title: 'Evento o rumor',
      icon: Icons.campaign_outlined,
      subtitle: 'Opcional, en tus palabras',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            enabled: !running,
            minLines: 2,
            maxLines: 4,
            maxLength: 2000,
            onChanged: (value) => ref
                .read(scenarioVariablesProvider.notifier)
                .setCustomEvent(value),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Ej.: "un tribunal frena las exportaciones a un mercado clave"',
              counterText: '',
            ),
          ),
          const SizedBox(height: 8),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 13, color: AppTheme.neutral),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'El evento NO se cuantifica: no mueve ninguno de los números proyectados. Se '
                  'explica en el texto, porque ponerle un porcentaje sería inventar un coeficiente '
                  'que nadie midió.',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: AppTheme.textMuted,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RunButton extends ConsumerWidget {
  const _RunButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(simulationControllerProvider);
    final variables = ref.watch(scenarioVariablesProvider);
    final stale = state.isStale(variables);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: state.isRunning
              ? null
              : () => ref.read(simulationControllerProvider.notifier).run(),
          icon: state.isRunning
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow_rounded, size: 18),
          label: Text(state.isRunning ? 'Simulando…' : 'Ejecutar simulación'),
        ),
        if (!variables.hasQuantitativeLever && variables.hasCustomEvent) ...[
          const SizedBox(height: 8),
          // Un escenario con solo un rumor es válido y se responde, pero su proyección es igual a la
          // base: decirlo antes evita que el 0% se lea como el resultado del análisis del rumor.
          const Text(
            'Con solo un evento descrito, la proyección va a ser igual a la base: el evento se '
            'explica pero no mueve números.',
            style: TextStyle(fontSize: 10.5, color: AppTheme.neutral, height: 1.35),
          ),
        ],
        if (stale) ...[
          const SizedBox(height: 8),
          const Text(
            'Cambiaste las palancas: el resultado de abajo es de la corrida anterior.',
            style: TextStyle(fontSize: 10.5, color: AppTheme.neutral, height: 1.35),
          ),
        ],
        if (state.errorMessage != null) ...[
          const SizedBox(height: 8),
          Text(
            state.errorMessage!,
            style: const TextStyle(fontSize: 11.5, color: AppTheme.bearish),
          ),
        ],
      ],
    );
  }
}

class _SimulationResults extends ConsumerWidget {
  const _SimulationResults();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(simulationControllerProvider);
    final result = state.result;

    if (result == null) {
      return const AnalysisCard(
        title: 'Resultado',
        icon: Icons.insights_outlined,
        child: Text(
          'Elegí las palancas y ejecutá la simulación. La proyección se calcula en el backend con '
          'una cascada determinística: los mismos supuestos dan siempre el mismo resultado.',
          style: TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.45),
        ),
      );
    }

    if (result.availability == DataAvailability.unavailable) {
      return AnalysisCard(
        title: 'Resultado',
        icon: Icons.insights_outlined,
        child: DegradationBanner(reason: result.degradationReason),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PriceImpactCard(result: result),
        const SizedBox(height: 12),
        _ProjectionCard(result: result),
        const SizedBox(height: 12),
        AnalysisCard(
          title: 'Matriz de sensibilidad',
          icon: Icons.grid_view_outlined,
          child: SensitivityMatrix(cases: result.sensitivity),
        ),
        if (result.customEvent != null) ...[
          const SizedBox(height: 12),
          _EventEchoCard(result: result),
        ],
        const SizedBox(height: 12),
        _AssumptionsCard(result: result),
        if (result.narrative != null) ...[
          const SizedBox(height: 12),
          _ScenarioNarrativeCard(result: result),
        ],
      ],
    );
  }
}

/// La variación estimada en la cotización, con su base de valuación a la vista.
class _PriceImpactCard extends ConsumerWidget {
  const _PriceImpactCard({required this.result});

  final ScenarioSimulationResult result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projection = result.projection;
    final change = projection.impliedPriceChangePct;
    final color = change == null
        ? AppTheme.textMuted
        : (change > 0
            ? AppTheme.bullish
            : (change < 0 ? AppTheme.bearish : AppTheme.accent));

    return AnalysisCard(
      title: 'Variación estimada en la cotización',
      icon: Icons.show_chart_outlined,
      trailing: SaveToLabButton(
        heading: 'Simulación de escenario de ${result.ticker}',
        draft: scenarioNoteDraft(result),
        snippet: buildScenarioNoteMarkdown(result),
        ticker: result.ticker,
        tooltip: 'Guardar la simulación en el Investment Lab',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (projection.impliedPrice == null)
            Text(
              // Los motivos posibles se arreglan distinto, y el backend manda cuál es. Un "—" acá
              // dejaría al usuario sin saber si falta un dato o si el cálculo no aplica.
              result.valuationNote ??
                  'No se puede estimar una variación de precio con estos datos.',
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.textMuted,
                height: 1.45,
              ),
            )
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  change == null ? kMissingValue : formatSurprisePct(change),
                  style: AppTheme.numeric(fontSize: 28, color: color)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'de ${formatEps(result.baseline.referencePrice)} '
                    'a ${formatEps(projection.impliedPrice)}',
                    style: AppTheme.numeric(
                      fontSize: 12,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.neutral.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: AppTheme.neutral.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, size: 14, color: AppTheme.neutral),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      // La aclaración va en un banner y no en letra chica: es la diferencia entre una
                      // medida de sensibilidad y un precio objetivo, y confundirlas es el error más
                      // caro que se puede cometer con esta pantalla.
                      '${result.valuationNote ?? ""}\n'
                      'NO es un precio objetivo: es cuánto se movería el precio si el mercado '
                      'siguiera pagando el mismo múltiplo por cada peso de ganancia.',
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: AppTheme.textMuted,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// La proyección línea por línea, con la base al lado.
class _ProjectionCard extends StatelessWidget {
  const _ProjectionCard({required this.result});

  final ScenarioSimulationResult result;

  @override
  Widget build(BuildContext context) {
    final baseline = result.baseline;
    final projection = result.projection;

    return AnalysisCard(
      title: 'Proyección',
      icon: Icons.trending_up_outlined,
      subtitle: 'Base: ${baseline.periodLabel ?? formatCorporateDate(baseline.periodEnd)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ProjectionRow(
            label: 'Ingresos',
            base: formatRevenue(baseline.revenue),
            projected: formatRevenue(projection.revenue),
            change: projection.revenueChangePct,
          ),
          _ProjectionRow(
            label: 'EBITDA',
            base: formatRevenue(baseline.ebitda),
            projected: formatRevenue(projection.ebitda),
            change: projection.ebitdaChangePct,
          ),
          _ProjectionRow(
            label: 'EPS',
            // La base del EPS es el punto cero del MODELO cuando difiere del reportado: es contra ese
            // número que se mide la variación, y mostrar el reportado acá haría que la cuenta no
            // cierre a la vista.
            base: formatEps(baseline.modelEps ?? baseline.eps),
            projected: formatEps(projection.eps),
            change: projection.epsChangePct,
          ),
          _ProjectionRow(
            label: 'Flujo de caja libre',
            base: formatRevenue(baseline.freeCashFlow),
            projected: formatRevenue(projection.freeCashFlow),
            change: projection.freeCashFlowChangePct,
          ),
          if (baseline.modelEpsDiffers) ...[
            const SizedBox(height: 8),
            Text(
              'El EPS base de la proyección (${formatEps(baseline.modelEps)}) no es el reportado '
              '(${formatEps(baseline.eps)}): la cascada del simulador no reproduce los resultados no '
              'operativos de la empresa, y las variaciones se miden contra su propio punto cero para '
              'que un escenario sin cambios dé exactamente 0%.',
              style: const TextStyle(
                fontSize: 10.5,
                color: AppTheme.textMuted,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProjectionRow extends StatelessWidget {
  const _ProjectionRow({
    required this.label,
    required this.base,
    required this.projected,
    required this.change,
  });

  final String label;
  final String base;
  final String projected;
  final double? change;

  @override
  Widget build(BuildContext context) {
    // La variable local es lo que le deja al analyzer promover el tipo: `change` es un campo y una
    // comparación directa sobre él no pasa el chequeo de nulabilidad.
    final delta = change;
    final color = delta == null
        ? null
        : (delta > 0
            ? AppTheme.bullish
            : (delta < 0 ? AppTheme.bearish : null));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              base,
              textAlign: TextAlign.right,
              style: AppTheme.numeric(fontSize: 11.5, color: AppTheme.textMuted),
            ),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.arrow_right_alt, size: 14, color: AppTheme.textMuted),
          const SizedBox(width: 6),
          Expanded(
            flex: 3,
            child: Text(
              projected,
              textAlign: TextAlign.right,
              style: AppTheme.numeric(fontSize: 12.5, color: color),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              delta == null ? '' : formatSurprisePct(delta),
              textAlign: TextAlign.right,
              style: AppTheme.numeric(fontSize: 11, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// El evento que el usuario escribió, con la aclaración de que no movió números.
class _EventEchoCard extends StatelessWidget {
  const _EventEchoCard({required this.result});

  final ScenarioSimulationResult result;

  @override
  Widget build(BuildContext context) {
    return AnalysisCard(
      title: 'Evento descrito',
      icon: Icons.campaign_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            result.customEvent!,
            style: const TextStyle(fontSize: 12.5, height: 1.45),
          ),
          if (result.customEventIsQualitative) ...[
            const SizedBox(height: 10),
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.functions_outlined, size: 13, color: AppTheme.neutral),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Este evento no está cuantificado: ninguno de los números de arriba lo incluye. '
                    'Su efecto se discute en el texto.',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: AppTheme.textMuted,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Los supuestos del modelo, tal como los manda el backend.
class _AssumptionsCard extends StatelessWidget {
  const _AssumptionsCard({required this.result});

  final ScenarioSimulationResult result;

  @override
  Widget build(BuildContext context) {
    return AnalysisCard(
      title: 'Supuestos del modelo',
      icon: Icons.rule_outlined,
      subtitle: 'Qué se mantuvo constante y con qué coeficientes',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final assumption in result.modelAssumptions)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 5, right: 8),
                    child: Icon(
                      Icons.circle,
                      size: 5,
                      color: AppTheme.textMuted,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      assumption,
                      style: const TextStyle(fontSize: 11.5, height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
          if (result.modelAssumptions.isEmpty)
            const Text(
              'Esta corrida no declaró supuestos.',
              style: TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
            ),
        ],
      ),
    );
  }
}

class _ScenarioNarrativeCard extends StatelessWidget {
  const _ScenarioNarrativeCard({required this.result});

  final ScenarioSimulationResult result;

  @override
  Widget build(BuildContext context) {
    return AnalysisCard(
      title: 'Lectura del escenario',
      icon: Icons.auto_awesome_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            result.narrative!,
            style: const TextStyle(fontSize: 13, height: 1.55),
          ),
          const SizedBox(height: 10),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 13, color: AppTheme.neutral),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Texto redactado por IA sobre la proyección ya calculada. No es una recomendación '
                  'de inversión.',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: AppTheme.textMuted,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
