import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../corporate/data/corporate_formatting.dart';
import '../data/ai_lab_models.dart';

/// Bloques de presentación del diagnóstico contable: márgenes, DuPont y banderas.
///
/// **El color acá es semántica, no decoración.** Verde y rojo se usan solo para el signo de una
/// bandera (fortaleza / riesgo), que es la única dimensión de este módulo donde significan lo que
/// significan en el resto de la app. Un margen alto NO se pinta de verde: un margen es un nivel, no
/// una dirección, y colorearlo convertiría una medición en un juicio.

Color flagColor(FlagKind kind) =>
    kind == FlagKind.red ? AppTheme.bearish : AppTheme.bullish;

/// El ícono acompaña al color porque el color solo no alcanza: un daltónico tiene que poder separar
/// un riesgo de una fortaleza, que es justamente la distinción que más importa acá.
IconData flagIcon(FlagKind kind, FlagSeverity severity) {
  if (kind == FlagKind.green) return Icons.check_circle_outline;
  return switch (severity) {
    FlagSeverity.critical => Icons.error_outline,
    FlagSeverity.warning => Icons.warning_amber_outlined,
    FlagSeverity.info => Icons.info_outline,
  };
}

/// Una fila de métrica etiquetada, en monoespaciada.
class MetricRow extends StatelessWidget {
  const MetricRow({
    super.key,
    required this.label,
    required this.value,
    this.caption,
    this.valueColor,
    this.dense = false,
  });

  final String label;
  final String value;
  final String? caption;
  final Color? valueColor;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 2 : 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: dense ? 11 : 12,
                    color: AppTheme.textMuted,
                  ),
                ),
                if (caption != null)
                  Text(
                    caption!,
                    style: const TextStyle(fontSize: 9.5, color: AppTheme.textMuted),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            value,
            style: AppTheme.numeric(
              fontSize: dense ? 12 : 13,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }
}

/// Tarjeta con título y cuerpo, el contenedor de todos los bloques del diagnóstico.
class AnalysisCard extends StatelessWidget {
  const AnalysisCard({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.trailing,
    this.subtitle,
  });

  final String title;
  final Widget child;
  final IconData? icon;
  final Widget? trailing;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: AppTheme.panelDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: AppTheme.accent),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: AppTheme.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

/// Los márgenes del último período, con el margen EBITDA marcado cuando fue reconstruido.
class MarginsBlock extends StatelessWidget {
  const MarginsBlock({super.key, required this.income});

  final IncomeStatementBlock income;

  @override
  Widget build(BuildContext context) {
    return AnalysisCard(
      title: 'Márgenes',
      subtitle: income.label,
      icon: Icons.percent_outlined,
      child: Column(
        children: [
          MetricRow(
            label: 'Ingresos',
            value: formatRevenue(income.revenue),
          ),
          MetricRow(
            label: 'Margen bruto',
            value: _pct(income.grossMarginPct),
          ),
          MetricRow(
            label: 'Margen operativo',
            value: _pct(income.operatingMarginPct),
          ),
          MetricRow(
            label: 'Margen EBITDA',
            // Se aclara cuándo el EBITDA lo reconstruyó el backend: el que la empresa informa en su
            // presentación suele excluir cargos no recurrentes, y presentarlos como el mismo número
            // le atribuiría a la empresa una cifra que no dijo.
            caption: income.ebitdaIsDerived
                ? 'EBITDA reconstruido: operativo + amortizaciones'
                : null,
            value: _pct(income.ebitdaMarginPct),
          ),
          MetricRow(
            label: 'Margen neto',
            value: _pct(income.netMarginPct),
          ),
          MetricRow(
            label: 'Tasa impositiva efectiva',
            value: _pct(income.effectiveTaxRatePct),
          ),
        ],
      ),
    );
  }
}

/// El balance del último período.
class BalanceBlockCard extends StatelessWidget {
  const BalanceBlockCard({super.key, required this.balance});

  final BalanceSheetBlock balance;

  @override
  Widget build(BuildContext context) {
    return AnalysisCard(
      title: 'Balance',
      subtitle: balance.periodLabel ?? formatCorporateDate(balance.periodEnd),
      icon: Icons.account_balance_outlined,
      child: Column(
        children: [
          MetricRow(label: 'Activo', value: formatRevenue(balance.totalAssets)),
          MetricRow(
            label: 'Pasivo',
            value: formatRevenue(balance.totalLiabilities),
          ),
          MetricRow(
            label: 'Patrimonio',
            value: formatRevenue(balance.totalEquity),
          ),
          MetricRow(
            label: 'Deuda total',
            value: formatRevenue(balance.totalDebt),
          ),
          MetricRow(
            label: 'Deuda neta',
            caption: balance.hasNetCash ? 'La caja supera a la deuda' : null,
            value: formatRevenue(balance.netDebt),
            // Único color del bloque, y solo en este campo: la caja neta es un signo (tiene o no
            // tiene más caja que deuda), no un nivel.
            valueColor: balance.hasNetCash ? AppTheme.bullish : null,
          ),
          MetricRow(
            label: 'Liquidez corriente',
            value: _multiple(balance.currentRatio),
          ),
          MetricRow(
            label: 'Deuda / Patrimonio',
            value: _multiple(balance.debtToEquity),
          ),
        ],
      ),
    );
  }
}

/// El flujo de caja del último período, con la conversión destacada.
class CashFlowBlockCard extends StatelessWidget {
  const CashFlowBlockCard({super.key, required this.cashFlow});

  final CashFlowBlock cashFlow;

  @override
  Widget build(BuildContext context) {
    return AnalysisCard(
      title: 'Caja',
      subtitle: cashFlow.periodLabel ?? formatCorporateDate(cashFlow.periodEnd),
      icon: Icons.water_drop_outlined,
      child: Column(
        children: [
          MetricRow(
            label: 'Caja operativa',
            value: formatRevenue(cashFlow.operatingCashFlow),
          ),
          MetricRow(
            label: 'Capex',
            value: formatRevenue(cashFlow.capitalExpenditure),
          ),
          MetricRow(
            label: 'Flujo de caja libre',
            caption: cashFlow.freeCashFlowIsDerived
                ? 'FCF reconstruido: caja operativa − capex'
                : null,
            value: formatRevenue(cashFlow.freeCashFlow),
          ),
          MetricRow(
            label: 'Conversión FCF / resultado neto',
            caption: 'Cuánto de la ganancia se vuelve caja',
            value: _pct(cashFlow.fcfConversionPct, decimals: 0),
          ),
        ],
      ),
    );
  }
}

/// La descomposición DuPont, con la lectura de qué factor pesa más.
///
/// El valor de este bloque no son los tres números: es la frase de abajo. Dos empresas con el mismo
/// ROE, una por margen y otra por deuda, son dos inversiones distintas — y eso es lo que el bloque
/// tiene que dejar dicho.
class DupontCard extends StatelessWidget {
  const DupontCard({super.key, required this.dupont});

  final DupontBlock dupont;

  @override
  Widget build(BuildContext context) {
    if (!dupont.isComplete) {
      return const AnalysisCard(
        title: 'DuPont',
        icon: Icons.call_split_outlined,
        child: Text(
          'No se pudo descomponer el ROE: faltan líneas del balance o del estado de resultados. '
          'No se estima con los datos parciales.',
          style: TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.4),
        ),
      );
    }

    final driver = dupont.dominantDriver;

    return AnalysisCard(
      title: 'DuPont — de dónde viene el ROE',
      icon: Icons.call_split_outlined,
      trailing: Text(
        _pct(dupont.roePct),
        style: AppTheme.numeric(fontSize: 17, color: AppTheme.accent)
            .copyWith(fontWeight: FontWeight.bold),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FactorRow(
            label: 'Margen neto',
            value: _pct(dupont.netMarginPct),
            highlighted: driver == DupontDriver.margin,
          ),
          const _FactorOperator(),
          _FactorRow(
            label: 'Rotación de activos',
            value: _multiple(dupont.assetTurnover),
            highlighted: driver == DupontDriver.turnover,
          ),
          const _FactorOperator(),
          _FactorRow(
            label: 'Apalancamiento',
            value: _multiple(dupont.equityMultiplier),
            highlighted: driver == DupontDriver.leverage,
          ),
          if (driver != null) ...[
            const SizedBox(height: 10),
            Text(
              'El factor que más pesa es ${dupontDriverLabel(driver)}.',
              style: const TextStyle(fontSize: 12, height: 1.4),
            ),
          ],
          const SizedBox(height: 8),
          // El ROE que se muestra es el producto de los tres factores, que es algebraicamente el ROE
          // directo. Decirlo evita que alguien busque un segundo número que no existe.
          const Text(
            'El ROE es el producto de los tres factores.',
            style: TextStyle(fontSize: 10, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }
}

class _FactorRow extends StatelessWidget {
  const _FactorRow({
    required this.label,
    required this.value,
    required this.highlighted,
  });

  final String label;
  final String value;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: highlighted
            ? AppTheme.accent.withValues(alpha: 0.10)
            : AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: highlighted
              ? AppTheme.accent.withValues(alpha: 0.40)
              : AppTheme.border,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: highlighted ? AppTheme.accent : null,
                fontWeight: highlighted ? FontWeight.w600 : null,
              ),
            ),
          ),
          Text(
            value,
            style: AppTheme.numeric(
              fontSize: 13,
              color: highlighted ? AppTheme.accent : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _FactorOperator extends StatelessWidget {
  const _FactorOperator();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 3),
        child: Center(
          child: Text(
            '×',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
        ),
      );
}

/// Las banderas rojas y verdes, con su umbral a la vista.
class FlagsBlock extends StatelessWidget {
  const FlagsBlock({super.key, required this.flags, required this.criteriaSource});

  final List<AnalysisFlag> flags;
  final CriteriaSource criteriaSource;

  @override
  Widget build(BuildContext context) {
    final red = flags.where((flag) => flag.kind == FlagKind.red).length;
    final green = flags.length - red;

    return AnalysisCard(
      title: 'Banderas',
      icon: Icons.flag_outlined,
      subtitle: flags.isEmpty
          ? null
          : '$red en rojo · $green en verde',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (flags.isEmpty)
            const Text(
              'Ninguna bandera se disparó con los umbrales del producto. No es un veredicto '
              'positivo: es que ninguna de las señales que este módulo mide cruzó su umbral.',
              style:
                  TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.4),
            )
          else
            for (final flag in flags) FlagTile(flag: flag),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.rule_outlined, size: 13, color: AppTheme.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  criteriaSourceCaption(criteriaSource),
                  style: const TextStyle(
                    fontSize: 10,
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

/// Una bandera. El detalle viene redactado por el backend con el valor medido y el umbral adentro.
class FlagTile extends StatelessWidget {
  const FlagTile({super.key, required this.flag});

  final AnalysisFlag flag;

  @override
  Widget build(BuildContext context) {
    final color = flagColor(flag.kind);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(flagIcon(flag.kind, flag.severity), size: 15, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        flag.title,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: color,
                        ),
                      ),
                    ),
                    if (flag.severity != FlagSeverity.info)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: AppTheme.badgeDecoration(color),
                        child: Text(
                          flagSeverityLabel(flag.severity),
                          style: AppTheme.numeric(fontSize: 8.5, color: color)
                              .copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  flag.detail,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppTheme.textMuted,
                    height: 1.4,
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

String _pct(double? value, {int decimals = 1}) {
  if (value == null) return kMissingValue;
  // Sin signo: un margen es un nivel, no una variación. `formatSurprisePct` le pondría un "+" que
  // sugeriría una mejora respecto de algo.
  final formatted = value.abs().toStringAsFixed(decimals).replaceAll('.', ',');
  return value < 0 ? '−$formatted%' : '$formatted%';
}

String _multiple(double? value) {
  if (value == null) return kMissingValue;
  return '${value.toStringAsFixed(2).replaceAll('.', ',')}x';
}
