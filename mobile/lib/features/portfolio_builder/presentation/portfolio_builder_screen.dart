import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/data_availability.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/degradation_banner.dart';
import '../../corporate/widgets/save_to_lab_sheet.dart';
import '../../tickers/presentation/ticker_search_field.dart';
import '../data/portfolio_builder_models.dart';
import '../data/portfolio_formatting.dart';
import '../data/portfolio_note_snippet.dart';
import '../widgets/allocation_pie.dart';
import '../widgets/budget_bar.dart';
import '../widgets/portfolio_metrics.dart';
import '../widgets/position_row.dart';
import 'portfolio_builder_controller.dart';

/// El Constructor de Portafolios.
///
/// Dos columnas en pantalla ancha —armado a la izquierda, resultado a la derecha— y apiladas en
/// angosto. El armado y el resultado están separados porque son dos cosas distintas: lo de la
/// izquierda es lo que el usuario propone, lo de la derecha es lo que el backend calculó. Mezclarlos
/// mostraría números "calculados" que nadie calculó todavía.
class PortfolioBuilderScreen extends ConsumerWidget {
  const PortfolioBuilderScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(portfolioDraftProvider);
    final simulation = ref.watch(portfolioSimulationProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Constructor de Portafolios'),
        actions: [
          if (simulation.hasResult)
            _SavePortfolioButton(result: simulation.result!),
          const SizedBox(width: 4),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          final builder = _BuilderColumn(draft: draft, simulation: simulation);
          final results = _ResultsColumn(simulation: simulation, draft: draft);

          if (!wide) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 32),
              children: [builder, const SizedBox(height: 20), results],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 8, 32),
                  children: [builder],
                ),
              ),
              Expanded(
                flex: 6,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(8, 16, 16, 32),
                  children: [results],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BuilderColumn extends ConsumerWidget {
  const _BuilderColumn({required this.draft, required this.simulation});

  final PortfolioDraft draft;
  final PortfolioSimulationState simulation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolved = {
      for (final item in simulation.result?.items ?? const []) item.ticker: item,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BudgetBar(result: simulation.result),
        const SizedBox(height: 16),
        Text('Posiciones', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          draft.isFull
              ? 'Llegaste al máximo de $kMaxPortfolioItems posiciones.'
              : 'Buscá una empresa para sumarla a la cartera.',
          style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
        ),
        const SizedBox(height: 10),
        if (!draft.isFull)
          TickerSearchField(
            // `ticker.assetType` NO se reenvía: es el tipo de instrumento CRUDO de Polygon (`CS`,
            // `ETF`, `ADRC`…), no el `AssetType` del producto, y mandarlo hace que el backend
            // rechace el cuerpo con un 422. El catálogo se sincroniza con `market=stocks`
            // (`polygon_client.py`), así que todo lo que sale del buscador es una acción.
            onSelected: (ticker) => ref
                .read(portfolioDraftProvider.notifier)
                .add(ticker.symbol, name: ticker.name),
          ),
        const SizedBox(height: 14),
        if (draft.isEmpty)
          const _EmptyPositions()
        else ...[
          for (final item in draft.items)
            PositionRow(
              key: ValueKey(item.ticker),
              item: item,
              resolved: resolved[item.ticker] as PortfolioAllocationItem?,
              enabled: !simulation.isRunning,
            ),
          _PercentageHint(draft: draft),
        ],
        const SizedBox(height: 6),
        _RunButton(draft: draft, simulation: simulation),
      ],
    );
  }
}

class _EmptyPositions extends StatelessWidget {
  const _EmptyPositions();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: AppTheme.border),
      ),
      child: const Text(
        'La cartera está vacía. Cada posición se puede expresar en unidades, en dólares o como '
        'porcentaje del presupuesto, y podés fijarle un precio esperado para simular una entrada '
        'distinta a la del mercado.',
        style: TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.45),
      ),
    );
  }
}

/// Aviso cuando los porcentajes pedidos no suman 100.
///
/// Se avisa ANTES de simular y sin bloquear: repartir 80% y dejar 20% en efectivo es una decisión
/// legítima, y pasarse de 100% también se puede querer ver. Lo que no puede pasar es que el usuario
/// se entere recién al ver el resultado.
class _PercentageHint extends StatelessWidget {
  const _PercentageHint({required this.draft});

  final PortfolioDraft draft;

  @override
  Widget build(BuildContext context) {
    final requested = draft.requestedPercentage;
    if (requested == 0) return const SizedBox.shrink();

    final over = requested > 100.0001;
    final under = requested < 99.9999;
    if (!over && !under) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            over ? Icons.warning_amber_outlined : Icons.info_outline,
            size: 13,
            color: over ? AppTheme.neutral : AppTheme.textMuted,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              over
                  ? 'Los porcentajes suman ${formatWeightPct(requested)}: se va a pedir más de lo '
                      'que hay en el presupuesto.'
                  : 'Los porcentajes suman ${formatWeightPct(requested)}: el resto queda en '
                      'efectivo.',
              style: TextStyle(
                fontSize: 10.5,
                color: over ? AppTheme.neutral : AppTheme.textMuted,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RunButton extends ConsumerWidget {
  const _RunButton({required this.draft, required this.simulation});

  final PortfolioDraft draft;
  final PortfolioSimulationState simulation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stale = simulation.isStale(draft.toRequest());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (stale)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Icon(Icons.sync_problem, size: 13, color: AppTheme.neutral),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Cambiaste algo desde la última simulación: lo de la derecha todavía muestra el '
                    'reparto anterior.',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: AppTheme.neutral,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
        FilledButton.icon(
          onPressed: draft.isEmpty || simulation.isRunning
              ? null
              : () => ref.read(portfolioSimulationProvider.notifier).run(),
          icon: simulation.isRunning
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.calculate_outlined, size: 16),
          label: Text(
            simulation.isRunning ? 'Calculando…' : 'Simular cartera',
          ),
        ),
        if (simulation.errorMessage != null) ...[
          const SizedBox(height: 8),
          Text(
            simulation.errorMessage!,
            style: const TextStyle(color: AppTheme.bearish, fontSize: 11.5),
          ),
        ],
      ],
    );
  }
}

class _ResultsColumn extends StatefulWidget {
  const _ResultsColumn({required this.simulation, required this.draft});

  final PortfolioSimulationState simulation;
  final PortfolioDraft draft;

  @override
  State<_ResultsColumn> createState() => _ResultsColumnState();
}

class _ResultsColumnState extends State<_ResultsColumn> {
  PieMode _mode = PieMode.asset;

  @override
  Widget build(BuildContext context) {
    final result = widget.simulation.result;
    if (result == null) return const _NoResultYet();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (result.availability != DataAvailability.available &&
            result.degradationReason != null) ...[
          DegradationBanner(reason: result.degradationReason),
          const SizedBox(height: 12),
        ],
        if (!result.hasAllocation)
          const _NothingFunded()
        else ...[
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(AppTheme.radius),
              border: Border.all(color: AppTheme.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Asignación',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    SegmentedButton<PieMode>(
                      segments: const [
                        ButtonSegment(
                          value: PieMode.asset,
                          label: Text('Activo', style: TextStyle(fontSize: 11)),
                        ),
                        ButtonSegment(
                          value: PieMode.sector,
                          label: Text('Sector', style: TextStyle(fontSize: 11)),
                        ),
                      ],
                      selected: {_mode},
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onSelectionChanged: (selection) =>
                          setState(() => _mode = selection.first),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                AllocationPie(result: result, mode: _mode),
                const SizedBox(height: 10),
                Text(
                  // Qué mide la torta. Sin esto, un 40% de esta pantalla y un 40% de la Auditoría se
                  // leen como lo mismo y no lo son.
                  'Porcentajes sobre el capital asignado (${formatUsd(result.allocatedAmount)}), '
                  'no sobre el presupuesto: el efectivo sin asignar va aparte.',
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: AppTheme.textMuted,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          RiskBadge(result: result),
          const SizedBox(height: 12),
          ReturnCard(result: result),
          if (result.unfunded.isNotEmpty) ...[
            const SizedBox(height: 12),
            _UnfundedCard(result: result),
          ],
          if (result.notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            _NotesCard(notes: result.notes),
          ],
        ],
      ],
    );
  }
}

class _NoResultYet extends StatelessWidget {
  const _NoResultYet();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
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
              const Icon(Icons.pie_chart_outline,
                  size: 16, color: AppTheme.accent),
              const SizedBox(width: 8),
              Text('Resultado', style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Armá la cartera y ejecutá la simulación. El reparto se calcula en el backend: las '
            'unidades son enteras y lo que no alcanza queda como efectivo sin asignar.',
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.textMuted,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _NothingFunded extends StatelessWidget {
  const _NothingFunded();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: AppTheme.border),
      ),
      child: const Text(
        'Ninguna posición quedó con capital asignado, así que no hay reparto que mostrar. El motivo '
        'de cada una está en su fila, a la izquierda.',
        style: TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.45),
      ),
    );
  }
}

class _UnfundedCard extends StatelessWidget {
  const _UnfundedCard({required this.result});

  final PortfolioSimulationResult result;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sin capital asignado',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          const Text(
            // No se las esconde: sacarlas dejaría al usuario buscando un símbolo que agregó y que
            // desapareció sin explicación.
            'Estas posiciones quedaron en cero y no entran en los porcentajes de arriba.',
            style: TextStyle(fontSize: 10.5, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 8),
          for (final item in result.unfunded)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 62,
                    child: Text(
                      item.ticker,
                      style: AppTheme.numeric(fontSize: 11.5)
                          .copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      item.note ?? 'Sin motivo declarado.',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.textMuted,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _NotesCard extends StatelessWidget {
  const _NotesCard({required this.notes});

  final List<String> notes;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.rule, size: 15, color: AppTheme.accent),
              const SizedBox(width: 8),
              Text(
                'Supuestos del cálculo',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final note in notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '· $note',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppTheme.textMuted,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Congela la simulación en una nota del Lab.
class _SavePortfolioButton extends StatelessWidget {
  const _SavePortfolioButton({required this.result});

  final PortfolioSimulationResult result;

  @override
  Widget build(BuildContext context) {
    return SaveToLabButton(
      heading: kPortfolioSnippetHeading,
      draft: portfolioNoteDraft(result),
      snippet: buildPortfolioNoteMarkdown(result),
      tooltip: 'Guardar el portafolio en el Investment Lab',
    );
  }
}
