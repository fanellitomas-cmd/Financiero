import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../corporate/data/corporate_formatting.dart';
import '../data/portfolio_builder_models.dart';
import '../data/portfolio_formatting.dart';
import '../presentation/portfolio_builder_controller.dart';

/// Una fila de la tabla de posiciones: tipo de asignación, valor, y precio esperado opcional.
///
/// El **precio esperado** es un switch y no un campo siempre visible por la misma razón que las
/// palancas del simulador de escenarios: `null` (usar el mercado) y `0` son escenarios distintos, y
/// un campo vacío no distingue "no lo fijé" de "lo fijé en cero".
class PositionRow extends ConsumerStatefulWidget {
  const PositionRow({
    super.key,
    required this.item,
    required this.resolved,
    this.enabled = true,
  });

  final PortfolioItemInput item;

  /// Lo que el backend devolvió para esta posición en la última simulación. `null` mientras no se
  /// haya simulado todavía: la fila se muestra igual, sin números calculados.
  final PortfolioAllocationItem? resolved;

  final bool enabled;

  @override
  ConsumerState<PositionRow> createState() => _PositionRowState();
}

class _PositionRowState extends ConsumerState<PositionRow> {
  late final TextEditingController _valueController;
  late final TextEditingController _priceController;

  @override
  void initState() {
    super.initState();
    _valueController = TextEditingController(text: _formatValue());
    _priceController = TextEditingController(
      text: _formatPrice(widget.item.customPrice),
    );
  }

  @override
  void didUpdateWidget(PositionRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // El texto se re-sincroniza SOLO cuando el cambio vino de afuera (por ejemplo al cambiar el tipo
    // de asignación, que reinicia el valor). Pisarlo en cada rebuild movería el cursor mientras el
    // usuario tipea.
    if (oldWidget.item.allocationType != widget.item.allocationType ||
        (oldWidget.item.allocationValue != widget.item.allocationValue &&
            double.tryParse(_valueController.text.replaceAll(',', '.')) !=
                widget.item.allocationValue)) {
      _valueController.text = _formatValue();
    }
  }

  /// Coma decimal, como el resto de la app. El parser de `_commitPrice` acepta coma y punto, así que
  /// pegar un precio copiado de otro lado sigue funcionando.
  static String _formatPrice(double? value) =>
      value == null ? '' : value.toStringAsFixed(2).replaceAll('.', ',');

  String _formatValue() {
    final value = widget.item.allocationValue;
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(2);
  }

  @override
  void dispose() {
    _valueController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  void _commitValue(String raw) {
    final parsed = double.tryParse(raw.replaceAll(',', '.'));
    if (parsed == null || parsed <= 0) {
      _valueController.text = _formatValue();
      return;
    }
    ref
        .read(portfolioDraftProvider.notifier)
        .setValue(widget.item.ticker, parsed);
  }

  void _commitPrice(String raw) {
    final parsed = double.tryParse(raw.replaceAll(',', '.'));
    ref.read(portfolioDraftProvider.notifier).setCustomPrice(
          widget.item.ticker,
          parsed != null && parsed > 0 ? parsed : null,
        );
    if (parsed == null || parsed <= 0) _priceController.clear();
  }

  void _toggleCustomPrice(bool on) {
    final controller = ref.read(portfolioDraftProvider.notifier);
    if (!on) {
      controller.setCustomPrice(widget.item.ticker, null);
      _priceController.clear();
      return;
    }
    // Al encender, se parte del precio de MERCADO cuando se lo conoce: arrancar en un número
    // arbitrario sería un supuesto que el usuario no eligió, y arrancar vacío deja la posición sin
    // precio hasta que escriba algo.
    final seed = widget.resolved?.marketPrice;
    final value = seed != null && seed > 0 ? seed : 1.0;
    controller.setCustomPrice(widget.item.ticker, value);
    _priceController.text = _formatPrice(value);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final resolved = widget.resolved;
    final usesCustom = item.usesCustomPrice;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
      decoration: BoxDecoration(
        color: usesCustom ? AppTheme.surface : AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(
          color: usesCustom
              ? AppTheme.accent.withValues(alpha: 0.35)
              : AppTheme.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(item: item, resolved: resolved, enabled: widget.enabled),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: _TypeSelector(item: item, enabled: widget.enabled),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _valueController,
                  enabled: widget.enabled,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  onSubmitted: _commitValue,
                  onTapOutside: (_) {
                    FocusManager.instance.primaryFocus?.unfocus();
                    _commitValue(_valueController.text);
                  },
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: 'Valor',
                    suffixText: allocationTypeSuffix(item.allocationType),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _CustomPriceControl(
            item: item,
            resolved: resolved,
            controller: _priceController,
            enabled: widget.enabled,
            onToggle: _toggleCustomPrice,
            onCommit: _commitPrice,
          ),
          if (resolved != null) ...[
            const SizedBox(height: 10),
            _ResolvedLine(resolved: resolved),
          ],
        ],
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({
    required this.item,
    required this.resolved,
    required this.enabled,
  });

  final PortfolioItemInput item;
  final PortfolioAllocationItem? resolved;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = resolved?.name ?? item.name;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.ticker,
                style: AppTheme.numeric(fontSize: 14)
                    .copyWith(fontWeight: FontWeight.bold),
              ),
              if (name != null)
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: AppTheme.textMuted,
                  ),
                ),
            ],
          ),
        ),
        if (resolved != null && resolved!.sector != 'SIN_CLASIFICAR')
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.surfaceSunken,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: AppTheme.border),
            ),
            child: Text(
              resolved!.sectorLabel,
              style: const TextStyle(fontSize: 9.5, color: AppTheme.textMuted),
            ),
          ),
        IconButton(
          onPressed: enabled
              ? () => ref
                  .read(portfolioDraftProvider.notifier)
                  .remove(item.ticker)
              : null,
          icon: const Icon(Icons.close, size: 16),
          tooltip: 'Sacar ${item.ticker} de la cartera',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

class _TypeSelector extends ConsumerWidget {
  const _TypeSelector({required this.item, required this.enabled});

  final PortfolioItemInput item;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SegmentedButton<AllocationType>(
      segments: [
        for (final type in AllocationType.values)
          ButtonSegment(
            value: type,
            label: Text(
              allocationTypeSuffix(type),
              style: const TextStyle(fontSize: 11),
            ),
            tooltip: allocationTypeLabel(type),
          ),
      ],
      selected: {item.allocationType},
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onSelectionChanged: enabled
          ? (selection) => ref
              .read(portfolioDraftProvider.notifier)
              .setType(item.ticker, selection.first)
          : null,
    );
  }
}

class _CustomPriceControl extends StatelessWidget {
  const _CustomPriceControl({
    required this.item,
    required this.resolved,
    required this.controller,
    required this.enabled,
    required this.onToggle,
    required this.onCommit,
  });

  final PortfolioItemInput item;
  final PortfolioAllocationItem? resolved;
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final ValueChanged<String> onCommit;

  @override
  Widget build(BuildContext context) {
    final usesCustom = item.usesCustomPrice;
    final market = resolved?.marketPrice;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                usesCustom ? 'Precio esperado' : 'Precio de mercado',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: usesCustom ? AppTheme.accent : null,
                ),
              ),
            ),
            if (!usesCustom)
              Text(
                market == null ? 'en vivo' : formatUsd(market),
                style: AppTheme.numeric(
                  fontSize: 12,
                  color: AppTheme.textMuted,
                ),
              ),
            Switch(
              value: usesCustom,
              onChanged: enabled ? onToggle : null,
            ),
          ],
        ),
        if (usesCustom)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    enabled: enabled,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    ],
                    onSubmitted: onCommit,
                    onTapOutside: (_) {
                      FocusManager.instance.primaryFocus?.unfocus();
                      onCommit(controller.text);
                    },
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixText: 'US\$ ',
                      helperText: 'Se usa este precio en lugar del de mercado',
                      helperStyle: TextStyle(fontSize: 10),
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text(
              'Apagado, la posición se calcula con la última cotización.',
              style: TextStyle(
                fontSize: 10.5,
                color: AppTheme.textMuted,
                height: 1.35,
              ),
            ),
          ),
      ],
    );
  }
}

/// Lo que el backend resolvió para esta posición.
class _ResolvedLine extends StatelessWidget {
  const _ResolvedLine({required this.resolved});

  final PortfolioAllocationItem resolved;

  @override
  Widget build(BuildContext context) {
    final gap = resolved.customPriceGapPct;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              _Chip(
                label: 'Unidades',
                value: '${resolved.units}',
                muted: resolved.isEmpty,
              ),
              _Chip(
                label: 'Invertido',
                value: formatUsd(resolved.investedAmount),
                muted: resolved.isEmpty,
              ),
              _Chip(
                label: 'Peso',
                value: formatWeightPct(resolved.percentageOfTotal),
                muted: resolved.isEmpty,
              ),
              _Chip(
                label: '1 año',
                value: formatSurprisePct(resolved.return1yPct),
                muted: resolved.return1yPct == null,
              ),
            ],
          ),
          if (gap != null) ...[
            const SizedBox(height: 6),
            Text(
              // La distancia contra el mercado es lo que hace juzgable el supuesto: "entro a US$ 80"
              // no dice nada hasta saber que el mercado está en 300.
              'El precio esperado está ${formatSurprisePct(gap)} respecto del de mercado '
              '(${formatUsd(resolved.marketPrice)}).',
              style: const TextStyle(
                fontSize: 10.5,
                color: AppTheme.textMuted,
                height: 1.35,
              ),
            ),
          ],
          if (resolved.note != null) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, size: 12, color: AppTheme.neutral),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    resolved.note!,
                    style: const TextStyle(
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

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.value, this.muted = false});

  final String label;
  final String value;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: AppTheme.numeric(fontSize: 8.5, color: AppTheme.textMuted)
              .copyWith(letterSpacing: 0.5),
        ),
        Text(
          value,
          style: AppTheme.numeric(
            fontSize: 12,
            color: muted ? AppTheme.textMuted : null,
          ),
        ),
      ],
    );
  }
}
