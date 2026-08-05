import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../data/portfolio_audit.dart';

/// Las cuatro secciones de la Auditoría de Portafolio, más las piezas que comparten.
///
/// Viven separadas de `portfolio_audit_sheet.dart` porque esa hoja ya carga con el manejo de
/// estados (cargando / error / recálculo en curso / cartera vacía) y meterle además cuatro
/// composiciones visuales la volvería imposible de leer.

/// Cabecera de sección: título, subtítulo opcional y un trailing para el chip de estado.
class AuditSectionHeader extends StatelessWidget {
  const AuditSectionHeader({
    super.key,
    required this.title,
    required this.icon,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2, right: 8),
          child: Icon(icon, size: 16, color: AppTheme.textMuted),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// Aviso de que falta un bloque, con el motivo que manda el backend.
///
/// Ámbar y no rojo: que falte una credencial o un dato de un proveedor no es la app rota, y
/// pintarlo de rojo haría que un entorno sin configurar pareciera roto.
class AuditNotice extends StatelessWidget {
  const AuditNotice({
    super.key,
    required this.message,
    this.icon = Icons.info_outline,
  });

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.neutral.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.neutral.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppTheme.neutral),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Color estable de un sector.
///
/// Se indexa por la posición del sector en su propio enum, NO por su posición en la lista que se
/// está dibujando: si se indexara por la lista, Tecnología cambiaría de color al entrar o salir
/// otro sector de la cartera, y comparar dos auditorías de un vistazo dejaría de ser posible.
///
/// `sinClasificar` va siempre en gris, fuera de la paleta: no es un sector más, es la ausencia de
/// uno, y darle un color propio lo haría pasar por una categoría real.
Color sectorColor(PortfolioSector sector) =>
    sector == PortfolioSector.sinClasificar
        ? AppTheme.textMuted
        : AppTheme.categorical(sector.index);

// --- Sección 1: síntesis de la IA -----------------------------------------------------------

/// Narrativa ejecutiva. Va primero porque es la que hilvana el resto: los números que siguen se
/// entienden mejor después de leer qué significan juntos.
class AiSummarySection extends StatelessWidget {
  const AiSummarySection({super.key, required this.audit});

  final PortfolioAudit audit;

  @override
  Widget build(BuildContext context) {
    final summary = audit.aiSummary;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AuditSectionHeader(
              title: 'Síntesis del agente',
              icon: Icons.auto_awesome,
            ),
            const SizedBox(height: 12),
            if (summary != null)
              Text(
                summary,
                style: const TextStyle(fontSize: 13, height: 1.5),
              )
            else
              AuditNotice(
                message: audit.degradationReason ??
                    'La narrativa no está disponible en este momento. Los cálculos de abajo '
                        'son propios y son datos reales.',
              ),
            // El motivo también se muestra CUANDO SÍ hay narrativa: puede haber degradado otro
            // bloque (sectores sin resolver, correlaciones sin medir) y el usuario tiene que
            // enterarse aunque la prosa haya salido bien.
            if (summary != null && audit.degradationReason != null) ...[
              const SizedBox(height: 12),
              AuditNotice(message: audit.degradationReason!),
            ],
          ],
        ),
      ),
    );
  }
}

// --- Sección 2: distribución por sectores ---------------------------------------------------

class SectorAllocationSection extends StatelessWidget {
  const SectorAllocationSection({super.key, required this.audit});

  final PortfolioAudit audit;

  @override
  Widget build(BuildContext context) {
    final allocations = audit.sectorAllocation;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AuditSectionHeader(
              title: 'Distribución por sectores',
              icon: Icons.pie_chart_outline,
              subtitle: allocations.isEmpty
                  ? null
                  : '${allocations.length} '
                      '${allocations.length == 1 ? "sector" : "sectores"} '
                      'en tu lista',
            ),
            const SizedBox(height: 14),
            if (allocations.isEmpty)
              const AuditNotice(
                message: 'No se pudo determinar el sector de ningún activo.',
                icon: Icons.pie_chart_outline,
              )
            else ...[
              _StackedBar(allocations: allocations),
              const SizedBox(height: 16),
              for (final allocation in allocations) ...[
                _SectorRow(allocation: allocation),
                if (allocation != allocations.last) const SizedBox(height: 12),
              ],
            ],
            if (!audit.sectorDataAvailable && allocations.isNotEmpty) ...[
              const SizedBox(height: 12),
              const AuditNotice(
                message:
                    'Ninguno de tus activos pudo clasificarse por sector, así que la '
                    'distribución no dice nada sobre cómo está repartida tu cartera.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Barra apilada con el reparto completo. Da la forma de la cartera de un vistazo, antes de
/// leer un solo número — que es justamente lo que un listado de porcentajes no logra.
class _StackedBar extends StatelessWidget {
  const _StackedBar({required this.allocations});

  final List<SectorAllocation> allocations;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 12,
        // `Row` con `Expanded` y flex proporcional, no anchos calculados a mano: así el reparto
        // es exacto para cualquier ancho de panel sin tener que medir el contenedor.
        //
        // `stretch` es imprescindible, no cosmético: en el eje transversal un `Row` le pasa a sus
        // hijos una restricción SUELTA (0 a 12), y un `ColoredBox` sin hijo adopta el mínimo — o
        // sea alto 0, una barra invisible. Con `stretch` la restricción pasa a ser ajustada y cada
        // tramo ocupa los 12px. (Acá es seguro porque el `SizedBox` de arriba acota el alto; un
        // `stretch` dentro de un `ListView` sin acotar daría alto infinito.)
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final allocation in allocations)
              Expanded(
                // El flex es entero, así que se escala el porcentaje para no perder los decimales
                // de un sector chico (14.29% -> 1429).
                flex: (allocation.weightPct * 100).round().clamp(1, 1000000),
                child: ColoredBox(color: sectorColor(allocation.sector)),
              ),
          ],
        ),
      ),
    );
  }
}

class _SectorRow extends StatelessWidget {
  const _SectorRow({required this.allocation});

  final SectorAllocation allocation;

  @override
  Widget build(BuildContext context) {
    final color = sectorColor(allocation.sector);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                allocation.label,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            Text(
              '${allocation.weightPct.toStringAsFixed(1)}%',
              style: AppTheme.numeric(fontSize: 13, color: color)
                  .copyWith(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        if (allocation.tickers.isNotEmpty) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 18),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final ticker in allocation.tickers)
                  _TickerChip(ticker: ticker, color: color),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _TickerChip extends StatelessWidget {
  const _TickerChip({required this.ticker, required this.color});

  final String ticker;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        ticker,
        style: AppTheme.tickerSymbol.copyWith(fontSize: 11, color: color),
      ),
    );
  }
}

// --- Sección 3: riesgo y concentración ------------------------------------------------------

/// Color del nivel de riesgo. Verde/ámbar/rojo acá SÍ corresponde: no es dirección de mercado,
/// es un semáforo de riesgo, que es el otro uso convencional de esos tres colores.
Color riskColor(RiskLevel level) => switch (level) {
      RiskLevel.baja => AppTheme.bullish,
      RiskLevel.moderada => AppTheme.neutral,
      RiskLevel.alta => AppTheme.bearish,
      RiskLevel.critica => AppTheme.bearish,
    };

String riskLabel(RiskLevel level) => switch (level) {
      RiskLevel.baja => 'RIESGO BAJO',
      RiskLevel.moderada => 'RIESGO MODERADO',
      RiskLevel.alta => 'RIESGO ALTO',
      RiskLevel.critica => 'RIESGO MUY ALTO',
    };

class ConcentrationSection extends StatelessWidget {
  const ConcentrationSection({super.key, required this.risk});

  final ConcentrationRisk? risk;

  @override
  Widget build(BuildContext context) {
    final value = risk;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AuditSectionHeader(
              title: 'Riesgo y concentración',
              icon: Icons.warning_amber_outlined,
              trailing: value == null ? null : _RiskBadge(level: value.level),
            ),
            const SizedBox(height: 14),
            if (value == null)
              const AuditNotice(
                message:
                    'No hay activos suficientes para medir la concentración.',
              )
            else ...[
              Text(
                value.headline,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: riskColor(value.level),
                    ),
              ),
              const SizedBox(height: 14),
              _RiskMeter(level: value.level),
              const SizedBox(height: 14),
              _ConcentrationStats(risk: value),
              if (value.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final note in value.notes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 6, right: 8),
                          child: SizedBox(
                            width: 4,
                            height: 4,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: AppTheme.textMuted,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            note,
                            style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _RiskBadge extends StatelessWidget {
  const _RiskBadge({required this.level});

  final RiskLevel level;

  @override
  Widget build(BuildContext context) {
    final color = riskColor(level);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: AppTheme.badgeDecoration(color),
      child: Text(
        riskLabel(level),
        style: AppTheme.numeric(fontSize: 10, color: color)
            .copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// Medidor de cuatro tramos. Se pintan todos los tramos hasta el nivel actual en vez de una barra
/// continua: el nivel es una categoría, no una magnitud, y una barra continua sugeriría una
/// precisión ("estás al 62% de riesgo") que el backend no afirma.
class _RiskMeter extends StatelessWidget {
  const _RiskMeter({required this.level});

  final RiskLevel level;

  @override
  Widget build(BuildContext context) {
    final color = riskColor(level);
    final filled = level.index + 1;

    return Row(
      children: [
        for (var index = 0; index < RiskLevel.values.length; index++) ...[
          Expanded(
            child: Container(
              height: 6,
              decoration: BoxDecoration(
                color: index < filled
                    ? color.withValues(alpha: index == filled - 1 ? 1 : 0.55)
                    : AppTheme.surfaceSunken,
                borderRadius: BorderRadius.circular(3),
                border: Border.all(
                  color: index < filled ? Colors.transparent : AppTheme.border,
                ),
              ),
            ),
          ),
          if (index < RiskLevel.values.length - 1) const SizedBox(width: 4),
        ],
      ],
    );
  }
}

class _ConcentrationStats extends StatelessWidget {
  const _ConcentrationStats({required this.risk});

  final ConcentrationRisk risk;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _Stat(
            label: 'Sector dominante',
            value: risk.topSectorLabel,
            emphasis: '${risk.topSectorWeightPct.toStringAsFixed(0)}%',
            color: sectorColor(risk.topSector),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _Stat(
            label: 'Sectores distintos',
            value: '${risk.distinctSectors}',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _Stat(
            label: 'Índice HHI',
            value: risk.herfindahlIndex.toStringAsFixed(2),
            // El HHI no es de conocimiento general y sin esta explicación es un número mudo.
            tooltip:
                'Índice de Herfindahl (0 a 1): mide qué tan repartida está la cartera. '
                '1 es todo en un solo sector; cuanto más bajo, más pareja la distribución.',
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    this.emphasis,
    this.color,
    this.tooltip,
  });

  final String label;
  final String value;
  final String? emphasis;
  final Color? color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 10,
                  ),
                ),
              ),
              if (tooltip != null)
                const Icon(Icons.help_outline,
                    size: 11, color: AppTheme.textMuted),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            emphasis ?? value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.numeric(fontSize: 15, color: color)
                .copyWith(fontWeight: FontWeight.bold),
          ),
          if (emphasis != null)
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
            ),
        ],
      ),
    );

    return tooltip == null
        ? content
        : Tooltip(message: tooltip!, child: content);
  }
}

// --- Sección 4: correlaciones y sugerencias -------------------------------------------------

class CorrelationSection extends StatelessWidget {
  const CorrelationSection({
    super.key,
    required this.warnings,
    required this.measured,
  });

  final List<CorrelationWarning> warnings;

  /// `true` si al menos un par se pudo medir contra precios reales.
  final bool measured;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AuditSectionHeader(
              title: 'Activos que se superponen',
              icon: Icons.compare_arrows,
              subtitle: warnings.isEmpty
                  ? null
                  : '${warnings.length} '
                      '${warnings.length == 1 ? "advertencia" : "advertencias"}',
            ),
            const SizedBox(height: 14),
            if (warnings.isEmpty)
              Text(
                // La diferencia entre "los medimos y no correlacionan" y "no los pudimos medir" no
                // es un matiz: en el segundo caso el usuario NO tiene la tranquilidad que el
                // primero le daría, y ambos se verían igual con un simple "sin advertencias".
                measured
                    ? 'No detectamos activos que se muevan casi igual entre sí.'
                    : 'No se pudo medir la correlación de precios entre tus activos, así que la '
                        'ausencia de advertencias no confirma que estén diversificados.',
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 12,
                  height: 1.4,
                ),
              )
            else
              for (final warning in warnings) ...[
                _WarningTile(warning: warning),
                if (warning != warnings.last) const SizedBox(height: 10),
              ],
          ],
        ),
      ),
    );
  }
}

class _WarningTile extends StatelessWidget {
  const _WarningTile({required this.warning});

  final CorrelationWarning warning;

  @override
  Widget build(BuildContext context) {
    // Una correlación medida sobre precios pesa más que una inferida de que dos empresas comparten
    // sector, y el chip lo dice sin necesitar una leyenda: cian (el acento, igual que los reportes
    // oficiales en la Ficha) contra gris.
    final color = warning.isMeasured ? AppTheme.accent : AppTheme.textMuted;
    final coefficient = warning.coefficient;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final ticker in warning.tickers)
                Text(
                  ticker,
                  style: AppTheme.tickerSymbol.copyWith(fontSize: 12),
                ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: color.withValues(alpha: 0.35)),
                ),
                child: Text(
                  warning.isMeasured ? 'MEDIDA' : 'POR SECTOR',
                  style: AppTheme.numeric(fontSize: 9, color: color)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              if (coefficient != null)
                Text(
                  'ρ ${coefficient >= 0 ? '+' : ''}${coefficient.toStringAsFixed(2)}',
                  style: AppTheme.numeric(fontSize: 11, color: color),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            warning.message,
            style: const TextStyle(fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class SuggestionsSection extends StatelessWidget {
  const SuggestionsSection({super.key, required this.suggestions});

  final List<DiversificationSuggestion> suggestions;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AuditSectionHeader(
              title: 'Sectores para balancear',
              icon: Icons.add_chart,
              // Se aclara que son sectores y no símbolos, porque es una decisión de producto y no
              // una limitación: sugerir un ticker concreto sería una recomendación de compra.
              subtitle:
                  'Sectores ausentes o con poco peso en tu lista, no recomendaciones '
                  'de compra',
            ),
            const SizedBox(height: 14),
            if (suggestions.isEmpty)
              const Text(
                'No hay sectores para sugerir con la información disponible.',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
              )
            else
              for (final suggestion in suggestions) ...[
                _SuggestionTile(suggestion: suggestion),
                if (suggestion != suggestions.last) const SizedBox(height: 10),
              ],
          ],
        ),
      ),
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({required this.suggestion});

  final DiversificationSuggestion suggestion;

  @override
  Widget build(BuildContext context) {
    final color = sectorColor(suggestion.sector);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: Text(
            suggestion.label,
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            suggestion.rationale,
            style: const TextStyle(
              color: AppTheme.textMuted,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
