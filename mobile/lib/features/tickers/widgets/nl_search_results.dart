import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../settings/data/exchange_type.dart';
import '../../watchlist/data/portfolio_audit.dart' show sectorDisplayName;
import '../../watchlist/widgets/audit_sections.dart' show sectorColor;
import '../data/nl_search_result.dart';
import '../presentation/nl_search_controller.dart';

/// La vista de resultados de la búsqueda conversacional.
///
/// El orden de arriba hacia abajo no es decorativo, es el orden en que el usuario necesita la
/// información para confiar (o desconfiar) de la lista:
///
///   1. **Qué entendió el agente** (`interpretation`). Es el modo de falla propio de una búsqueda en
///      lenguaje natural: si entendió otra cosa, todo lo de abajo es correcto y a la vez inútil, y
///      sin mostrarlo el usuario no tiene forma de darse cuenta.
///   2. **Qué no se pudo aplicar** (`unappliedCriteria`). Su ausencia cambia el significado de la
///      lista: sin el filtro de P/E, estos resultados NO cumplen lo que se pidió.
///   3. **Los resultados**, cada uno con la razón exacta por la que entró.
class NlSearchResultsView extends StatelessWidget {
  const NlSearchResultsView({
    super.key,
    required this.state,
    required this.onOpenTicker,
    required this.onExampleTapped,
  });

  final NlSearchState state;
  final ValueChanged<NlTickerMatch>? onOpenTicker;
  final ValueChanged<String> onExampleTapped;

  @override
  Widget build(BuildContext context) {
    final error = state.errorMessage;
    if (error != null) {
      return _CenteredMessage(
        icon: Icons.cloud_off_outlined,
        message: error,
      );
    }

    final result = state.result;
    if (result == null) {
      // Primera apertura: en vez de un vacío, ejemplos que se pueden tocar. Una búsqueda
      // conversacional sin ejemplos deja al usuario adivinando qué tipo de frase entiende.
      return _EmptyPrompt(onExampleTapped: onExampleTapped);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        _InterpretationCard(result: result),
        if (result.unappliedCriteria.isNotEmpty) ...[
          const SizedBox(height: 12),
          _UnappliedCriteriaBanner(criteria: result.unappliedCriteria),
        ],
        if (result.degradationReason != null &&
            result.unappliedCriteria.isEmpty) ...[
          const SizedBox(height: 12),
          _Notice(message: result.degradationReason!),
        ],
        const SizedBox(height: 16),
        if (result.isEmpty)
          _NoMatches(result: result)
        else ...[
          _ResultsHeader(result: result),
          const SizedBox(height: 10),
          for (final match in result.results) ...[
            _MatchTile(
              match: match,
              onTap: onOpenTicker == null ? null : () => onOpenTicker!(match),
            ),
            if (match != result.results.last) const SizedBox(height: 10),
          ],
        ],
      ],
    );
  }
}

/// Qué entendió el agente, más los criterios que dedujo como chips.
///
/// Los chips existen para que una mala interpretación se detecte de un vistazo: leer "P/E < 15" y
/// darse cuenta de que uno no pidió eso es más rápido que deducirlo de una lista de resultados
/// inesperados.
class _InterpretationCard extends StatelessWidget {
  const _InterpretationCard({required this.result});

  final NlSearchResult result;

  @override
  Widget build(BuildContext context) {
    final interpretation = result.interpretation;
    final chips = _criteriaChips(result.criteria);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                result.wasInterpreted ? Icons.auto_awesome : Icons.abc,
                size: 14,
                color: result.wasInterpreted
                    ? AppTheme.accent
                    : AppTheme.textMuted,
              ),
              const SizedBox(width: 7),
              Text(
                result.wasInterpreted
                    ? 'ASÍ ENTENDÍ TU BÚSQUEDA'
                    : 'BÚSQUEDA POR TEXTO',
                style: AppTheme.numeric(
                  fontSize: 9,
                  color: result.wasInterpreted
                      ? AppTheme.accent
                      : AppTheme.textMuted,
                ).copyWith(fontWeight: FontWeight.bold, letterSpacing: 0.5),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            interpretation ??
                // Sin interpretación, se dice qué se hizo en su lugar. Presentar una búsqueda por
                // coincidencia de texto como si fuera conversacional sería mentir sobre lo que pasó.
                'Se buscó «${result.query}» por coincidencia en el símbolo y el nombre, '
                    'sin interpretar la consulta.',
            style: const TextStyle(fontSize: 13, height: 1.45),
          ),
          if (chips.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final chip in chips) _CriterionChip(label: chip)],
            ),
          ],
        ],
      ),
    );
  }

  static List<String> _criteriaChips(SearchCriteria criteria) => [
        for (final sector in criteria.sectors) sectorDisplayName(sector),
        for (final exchange in criteria.exchanges) exchange.displayName,
        ...criteria.numericLabels,
        if (criteria.textQuery != null) '«${criteria.textQuery}»',
      ];
}

class _CriterionChip extends StatelessWidget {
  const _CriterionChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.border),
      ),
      child: Text(
        label,
        style: AppTheme.numeric(fontSize: 10, color: AppTheme.textMuted),
      ),
    );
  }
}

/// Los criterios que el usuario pidió y que NO se pudieron filtrar.
///
/// Es el banner más importante de la pantalla y por eso va en ámbar y con los criterios listados uno
/// por uno: presentar una lista filtrada solo por sector como si cumpliera "P/E menor a 15" sería
/// una respuesta falsa, y un aviso genérico ("faltan datos") no alcanza para que el usuario sepa
/// qué parte de su búsqueda quedó sin aplicar.
class _UnappliedCriteriaBanner extends StatelessWidget {
  const _UnappliedCriteriaBanner({required this.criteria});

  final List<String> criteria;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.neutral.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.neutral.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.filter_alt_off_outlined,
                  size: 15, color: AppTheme.neutral),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  criteria.length == 1
                      ? 'Un filtro no se pudo aplicar'
                      : '${criteria.length} filtros no se pudieron aplicar',
                  style: const TextStyle(
                    color: AppTheme.neutral,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final criterion in criteria)
            Padding(
              padding: const EdgeInsets.only(left: 23, bottom: 3),
              child: Text(
                '· $criterion',
                style: AppTheme.numeric(
                  fontSize: 11,
                  color: AppTheme.textMuted,
                ),
              ),
            ),
          const SizedBox(height: 6),
          const Padding(
            padding: EdgeInsets.only(left: 23),
            child: Text(
              'Los resultados de abajo NO cumplen necesariamente esa parte de tu búsqueda.',
              style: TextStyle(
                color: AppTheme.textMuted,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.message});

  final String message;

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
          const Icon(Icons.info_outline, size: 15, color: AppTheme.neutral),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultsHeader extends StatelessWidget {
  const _ResultsHeader({required this.result});

  final NlSearchResult result;

  @override
  Widget build(BuildContext context) {
    final count = result.results.length;
    // Se dice cuántos candidatos se evaluaron: "3 resultados" sin ese número se lee como si el
    // catálogo tuviera 3 símbolos.
    final evaluated = result.candidatesEvaluated;

    return Row(
      children: [
        Text(
          count == 1 ? '1 activo encontrado' : '$count activos encontrados',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(width: 8),
        if (evaluated > count)
          Text(
            'de $evaluated evaluados',
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
          ),
      ],
    );
  }
}

class _MatchTile extends StatelessWidget {
  const _MatchTile({required this.match, required this.onTap});

  final NlTickerMatch match;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = sectorColor(match.sector);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.surfaceSunken,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(match.symbol, style: AppTheme.tickerSymbol),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      match.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  _SectorBadge(label: match.sectorLabel, color: color),
                  if (match.exchange != null) ...[
                    const SizedBox(width: 6),
                    _ExchangeBadge(exchange: match.exchange!),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              // La razón de coincidencia es el corazón de la fila: la compone el backend con los
              // valores que efectivamente midió, así que es verificable — y sin ella una lista de
              // símbolos "encontrados por IA" sería un acto de fe.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2, right: 6),
                    child: Icon(Icons.check_circle_outline,
                        size: 12, color: AppTheme.bullish),
                  ),
                  Expanded(
                    child: Text(
                      match.matchReason,
                      style: const TextStyle(fontSize: 12, height: 1.4),
                    ),
                  ),
                ],
              ),
              if (match.ratioChips.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (label, value) in match.ratioChips)
                      _RatioChip(label: label, value: value),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SectorBadge extends StatelessWidget {
  const _SectorBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _ExchangeBadge extends StatelessWidget {
  const _ExchangeBadge({required this.exchange});

  final ExchangeType exchange;

  @override
  Widget build(BuildContext context) {
    // Mismos colores por bolsa que el buscador del catálogo, para que un NASDAQ se vea igual en las
    // dos búsquedas.
    final color = switch (exchange) {
      ExchangeType.nasdaq => AppTheme.bullish,
      ExchangeType.nyse => AppTheme.accent,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: AppTheme.badgeDecoration(color),
      child: Text(
        exchange.displayName,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _RatioChip extends StatelessWidget {
  const _RatioChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 9),
          ),
          const SizedBox(width: 4),
          Text(value, style: AppTheme.numeric(fontSize: 10)),
        ],
      ),
    );
  }
}

/// Sin coincidencias. Se explica el motivo más probable según lo que se pudo aplicar, en vez de un
/// "sin resultados" seco: con los criterios a la vista arriba, el usuario puede ver si el problema
/// fue la interpretación o el catálogo.
class _NoMatches extends StatelessWidget {
  const _NoMatches({required this.result});

  final NlSearchResult result;

  @override
  Widget build(BuildContext context) {
    final evaluated = result.candidatesEvaluated;

    return Column(
      children: [
        const SizedBox(height: 12),
        const Icon(Icons.search_off, size: 36, color: AppTheme.textMuted),
        const SizedBox(height: 14),
        Text(
          evaluated > 0
              ? 'Se evaluaron $evaluated activos del catálogo y ninguno cumple todos los '
                  'criterios. Probá aflojar alguno.'
              : 'Ningún activo del catálogo coincide con esos criterios. Si el catálogo '
                  'nunca se sincronizó en el backend, todas las búsquedas van a volver vacías.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppTheme.textMuted,
            fontSize: 12,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

/// Estado inicial: ejemplos tocables.
///
/// No es relleno: una búsqueda conversacional sin ejemplos deja al usuario adivinando qué clase de
/// frase entiende el sistema, y la primera consulta fallida es la que hace que no vuelva a usarla.
class _EmptyPrompt extends StatelessWidget {
  const _EmptyPrompt({required this.onExampleTapped});

  final ValueChanged<String> onExampleTapped;

  static const _examples = [
    'tecnológicas grandes con poca deuda',
    'acciones baratas que generen caja',
    'empresas de salud en crecimiento',
    'financieras del NYSE con buen ROE',
  ];

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      children: [
        const Icon(Icons.auto_awesome, size: 32, color: AppTheme.textMuted),
        const SizedBox(height: 14),
        const Text(
          'Escribí qué tipo de activo buscás, como se lo contarías a alguien.',
          textAlign: TextAlign.center,
          style:
              TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 20),
        Text(
          'PROBÁ CON',
          textAlign: TextAlign.center,
          style: AppTheme.numeric(fontSize: 9, color: AppTheme.textMuted)
              .copyWith(fontWeight: FontWeight.bold, letterSpacing: 0.6),
        ),
        const SizedBox(height: 10),
        for (final example in _examples)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ExampleChip(
              text: example,
              onTap: () => onExampleTapped(example),
            ),
          ),
      ],
    );
  }
}

class _ExampleChip extends StatelessWidget {
  const _ExampleChip({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.surfaceSunken,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(text, style: const TextStyle(fontSize: 13)),
              ),
              const Icon(Icons.north_east, size: 13, color: AppTheme.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: AppTheme.textMuted),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
