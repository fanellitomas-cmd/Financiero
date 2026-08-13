import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../data/portfolio_builder_models.dart';
import '../data/portfolio_formatting.dart';

/// Qué reparte la torta: por activo o por sector.
enum PieMode { asset, sector }

/// Torta de asignación, con leyenda propia y toque para resaltar.
///
/// **La leyenda es parte del gráfico, no un adorno.** Con más de cuatro porciones los títulos dentro
/// de la torta se pisan, así que adentro va solo el porcentaje de la porción tocada y los nombres van
/// afuera con su color al lado. Una torta con etiquetas ilegibles obliga a adivinar cuál es cuál.
class AllocationPie extends StatefulWidget {
  const AllocationPie({super.key, required this.result, required this.mode});

  final PortfolioSimulationResult result;
  final PieMode mode;

  @override
  State<AllocationPie> createState() => _AllocationPieState();
}

class _AllocationPieState extends State<AllocationPie> {
  int? _touched;

  @override
  void didUpdateWidget(AllocationPie oldWidget) {
    super.didUpdateWidget(oldWidget);
    // El índice tocado se suelta al cambiar de modo o de resultado: mantenerlo resaltaría una
    // porción distinta de la que el usuario había tocado.
    if (oldWidget.mode != widget.mode ||
        oldWidget.result != widget.result) {
      _touched = null;
    }
  }

  List<_Slice> get _slices {
    if (widget.mode == PieMode.sector) {
      return [
        for (var index = 0;
            index < widget.result.sectorAllocation.length;
            index++)
          _Slice(
            label: widget.result.sectorAllocation[index].label,
            weight: widget.result.sectorAllocation[index].percentageOfTotal,
            amount: widget.result.sectorAllocation[index].amount,
            color: sliceColor(index),
          ),
      ];
    }
    final funded = widget.result.funded;
    return [
      for (var index = 0; index < funded.length; index++)
        _Slice(
          label: funded[index].ticker,
          weight: funded[index].percentageOfTotal,
          amount: funded[index].investedAmount,
          color: sliceColor(index),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final slices = _slices;
    if (slices.isEmpty) return const SizedBox.shrink();

    final selected = _touched != null && _touched! < slices.length
        ? slices[_touched!]
        : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 420;
        final chart = SizedBox(
          height: 190,
          width: 190,
          child: Stack(
            alignment: Alignment.center,
            children: [
              PieChart(
                PieChartData(
                  sectionsSpace: 2,
                  centerSpaceRadius: 52,
                  sections: [
                    for (var index = 0; index < slices.length; index++)
                      PieChartSectionData(
                        value: slices[index].weight,
                        color: slices[index].color,
                        radius: _touched == index ? 40 : 34,
                        showTitle: false,
                      ),
                  ],
                  pieTouchData: PieTouchData(
                    touchCallback: (event, response) {
                      final section = response?.touchedSection;
                      setState(() {
                        _touched = event.isInterestedForInteractions &&
                                section != null
                            ? section.touchedSectionIndex
                            : null;
                      });
                    },
                  ),
                ),
              ),
              // El centro muestra la porción tocada, y sin toque el total: así el hueco del donut
              // siempre dice algo en vez de ser un agujero decorativo.
              _Center(selected: selected, result: widget.result),
            ],
          ),
        );

        final legend = _Legend(
          slices: slices,
          touched: _touched,
          onTap: (index) => setState(
            () => _touched = _touched == index ? null : index,
          ),
        );

        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: chart),
              const SizedBox(height: 14),
              legend,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            chart,
            const SizedBox(width: 18),
            Expanded(child: legend),
          ],
        );
      },
    );
  }
}

class _Slice {
  const _Slice({
    required this.label,
    required this.weight,
    required this.amount,
    required this.color,
  });

  final String label;
  final double weight;
  final double amount;
  final Color color;
}

class _Center extends StatelessWidget {
  const _Center({required this.selected, required this.result});

  final _Slice? selected;
  final PortfolioSimulationResult result;

  @override
  Widget build(BuildContext context) {
    final slice = selected;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          slice == null
              ? formatWeightPct(100)
              : formatWeightPct(slice.weight),
          style: AppTheme.numeric(
            fontSize: 18,
            color: slice?.color ?? AppTheme.accent,
          ).copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 2),
        SizedBox(
          width: 88,
          child: Text(
            slice?.label ?? 'asignado',
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
          ),
        ),
        Text(
          formatUsdCompact(slice?.amount ?? result.allocatedAmount),
          style: AppTheme.numeric(fontSize: 10, color: AppTheme.textMuted),
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.slices,
    required this.touched,
    required this.onTap,
  });

  final List<_Slice> slices;
  final int? touched;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < slices.length; index++)
          InkWell(
            onTap: () => onTap(index),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: slices[index].color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      slices[index].label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: touched == index
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                  Text(
                    formatWeightPct(slices[index].weight),
                    style: AppTheme.numeric(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
