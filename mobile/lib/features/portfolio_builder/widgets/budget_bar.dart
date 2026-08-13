import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../data/portfolio_builder_models.dart';
import '../data/portfolio_formatting.dart';
import '../presentation/portfolio_builder_controller.dart';

/// Presupuesto de la cartera, con el estado del reparto al lado.
///
/// Los badges de efectivo y de exceso son **excluyentes**: una cartera no puede tener sobrante y
/// pasarse a la vez, y mostrar los dos campos siempre (uno en cero) obligaría a leer cuál de los dos
/// está activo. Se muestra el que corresponde.
class BudgetBar extends ConsumerStatefulWidget {
  const BudgetBar({super.key, this.result});

  final PortfolioSimulationResult? result;

  @override
  ConsumerState<BudgetBar> createState() => _BudgetBarState();
}

class _BudgetBarState extends ConsumerState<BudgetBar> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    final budget = ref.read(portfolioDraftProvider).totalBudget;
    _controller = TextEditingController(text: budget.toStringAsFixed(0));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commit(String raw) {
    final parsed = double.tryParse(raw.replaceAll('.', '').replaceAll(',', '.'));
    if (parsed == null || parsed <= 0) {
      // Se restaura el valor vigente en vez de dejar el campo en un estado inválido: un presupuesto
      // vacío haría que toda la pantalla de abajo hable de una cartera sin plata.
      _controller.text =
          ref.read(portfolioDraftProvider).totalBudget.toStringAsFixed(0);
      return;
    }
    ref.read(portfolioDraftProvider.notifier).setBudget(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: AppTheme.border),
      ),
      child: Wrap(
        spacing: 16,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 220,
            child: TextField(
              controller: _controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              textInputAction: TextInputAction.done,
              onSubmitted: _commit,
              onTapOutside: (_) {
                FocusManager.instance.primaryFocus?.unfocus();
                _commit(_controller.text);
              },
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Presupuesto',
                prefixText: 'US\$ ',
                helperText: 'Lo que tenés para repartir',
                helperStyle: TextStyle(fontSize: 10.5),
              ),
            ),
          ),
          if (result != null) ...[
            _Metric(
              label: 'Asignado',
              value: formatUsd(result.allocatedAmount),
              color: AppTheme.accent,
            ),
            if (result.isOverBudget)
              _Metric(
                label: 'Exceso',
                value: formatUsd(result.overBudgetAmount),
                color: AppTheme.bearish,
                // El exceso lleva ícono porque es la única de las tres métricas que exige una
                // decisión: las otras dos son estados normales del reparto.
                icon: Icons.error_outline,
              )
            else
              _Metric(
                label: 'Sin asignar',
                value: '${formatUsd(result.cashUnallocated)} '
                    '(${formatWeightPct(result.cashPct)})',
                color: AppTheme.textMuted,
              ),
          ],
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.color,
    this.icon,
  });

  final String label;
  final String value;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 4),
            ],
            Text(
              label.toUpperCase(),
              style: AppTheme.numeric(fontSize: 9.5, color: AppTheme.textMuted)
                  .copyWith(letterSpacing: 0.6),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: AppTheme.numeric(fontSize: 14, color: color)
              .copyWith(fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}
