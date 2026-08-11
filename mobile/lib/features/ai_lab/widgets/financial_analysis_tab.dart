import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/degradation_banner.dart';
import '../../corporate/widgets/save_to_lab_sheet.dart';
import '../data/ai_lab_models.dart';
import '../data/ai_lab_note_snippet.dart';
import '../presentation/ai_lab_controller.dart';
import 'analysis_blocks.dart';
import 'analysis_chat.dart';

/// Pestaña "Análisis contable": los estados del activo, sus banderas y el hilo de conversación.
///
/// En pantalla ancha los bloques y el chat van en dos columnas, y en angosta uno abajo del otro. No es
/// solo estética: el chat se apoya en los números de al lado —"¿de dónde viene el ROE?" se contesta
/// mirando el DuPont— y tenerlos a la vista al mismo tiempo es lo que hace verificable la respuesta.
class FinancialAnalysisTab extends ConsumerWidget {
  const FinancialAnalysisTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(analysisControllerProvider);

    if (state.ticker == null) {
      return const _NeedsTicker();
    }

    if (state.isLoading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                // Se avisa que puede tardar: el backend cruza tres estados contables más una llamada
                // al modelo, y un spinner mudo de varios segundos parece que se colgó.
                'Leyendo los estados contables de ${state.ticker}…\n'
                'La primera vez puede tardar unos segundos.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.textMuted, height: 1.45),
              ),
            ],
          ),
        ),
      );
    }

    final analysis = state.analysis;
    if (analysis == null) {
      return _AnalysisError(
        message: state.errorMessage ??
            'No se pudo traer el diagnóstico contable en este momento.',
        onRetry: () => ref
            .read(analysisControllerProvider.notifier)
            .load(state.ticker!, force: true),
      );
    }

    return _AnalysisBody(analysis: analysis);
  }
}

class _AnalysisBody extends ConsumerWidget {
  const _AnalysisBody({required this.analysis});

  final FinancialAnalysisResponse analysis;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final degraded = analysis.availability == DataAvailability.unavailable;
    final income = analysis.latestIncome;
    final balance = analysis.latestBalance;
    final cashFlow = analysis.latestCashFlow;

    final blocks = <Widget>[
      _AnalysisHeader(analysis: analysis),
      const SizedBox(height: 12),
      if (degraded) ...[
        DegradationBanner(reason: analysis.degradationReason),
        const SizedBox(height: 14),
      ],
      if (income != null) ...[
        MarginsBlock(income: income),
        const SizedBox(height: 12),
      ],
      if (balance != null) ...[
        BalanceBlockCard(balance: balance),
        const SizedBox(height: 12),
      ],
      if (cashFlow != null) ...[
        CashFlowBlockCard(cashFlow: cashFlow),
        const SizedBox(height: 12),
      ],
      DupontCard(dupont: analysis.dupont),
      const SizedBox(height: 12),
      FlagsBlock(
        flags: analysis.flags,
        criteriaSource: analysis.dupont.criteriaSource,
      ),
      if (analysis.incomeStatements.length > 1) ...[
        const SizedBox(height: 12),
        _HistoryTable(statements: analysis.incomeStatements),
      ],
    ];

    final conversation = <Widget>[
      _NarrativeCard(analysis: analysis),
      const SizedBox(height: 14),
      if (analysis.hasStatements) AnalysisChat(analysis: analysis),
    ];

    if (context.isDesktop) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: blocks,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: conversation,
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [...blocks, const SizedBox(height: 18), ...conversation],
    );
  }
}

class _AnalysisHeader extends ConsumerWidget {
  const _AnalysisHeader({required this.analysis});

  final FinancialAnalysisResponse analysis;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = analysis.companyName;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                analysis.ticker,
                style: AppTheme.tickerSymbol.copyWith(fontSize: 18),
              ),
              Text(
                [
                  if (name != null) name,
                  '${statementPeriodLabel(analysis.period)} · '
                      '${analysis.incomeStatements.length} período(s)',
                ].join(' · '),
                style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
              ),
            ],
          ),
        ),
        if (analysis.servedFromCache)
          const Tooltip(
            // El backend cachea los estados seis horas porque un balance publicado no cambia hasta el
            // próximo reporte. Decirlo evita que un dato estable se lea como un dato congelado.
            message: 'Estados servidos de la caché del servidor (se refrescan cada 6 h).',
            child: Icon(Icons.bolt_outlined, size: 15, color: AppTheme.textMuted),
          ),
        if (analysis.hasStatements)
          SaveToLabButton(
            heading: 'Diagnóstico contable de ${analysis.ticker}',
            draft: analysisNoteDraft(analysis),
            snippet: buildAnalysisNoteMarkdown(analysis),
            ticker: analysis.ticker,
            tooltip: 'Guardar el diagnóstico en el Investment Lab',
          ),
        IconButton(
          icon: const Icon(Icons.refresh, size: 18),
          tooltip: 'Volver a leer los estados',
          onPressed: () => ref
              .read(analysisControllerProvider.notifier)
              .load(analysis.ticker, force: true),
        ),
      ],
    );
  }
}

/// La lectura general del modelo sobre los números.
///
/// Lleva SIEMPRE la marca de que la escribió una IA sobre cifras ya calculadas. Sin eso, un párrafo
/// bien escrito arriba de una tabla de márgenes se lee con la misma autoridad que los márgenes — y no
/// la tiene.
class _NarrativeCard extends ConsumerWidget {
  const _NarrativeCard({required this.analysis});

  final FinancialAnalysisResponse analysis;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final narrative = analysis.narrative;

    if (narrative == null || narrative.trim().isEmpty) {
      return AnalysisCard(
        title: 'Lectura del analista',
        icon: Icons.auto_awesome_outlined,
        child: DegradationBanner(
          icon: Icons.auto_awesome_outlined,
          reason: analysis.narrativeDegradationReason ??
              (analysis.hasStatements
                  ? 'Todavía no hay una lectura escrita de estos estados.'
                  : 'Sin estados contables no se le pide una lectura al modelo: escribiría sobre '
                      'un conjunto vacío.'),
        ),
      );
    }

    return AnalysisCard(
      title: 'Lectura del analista',
      icon: Icons.auto_awesome_outlined,
      trailing: analysis.history.isEmpty
          ? null
          : SaveToLabButton(
              heading: 'Consulta contable sobre ${analysis.ticker}',
              draft: conversationNoteDraft(analysis),
              snippet: buildConversationNoteMarkdown(analysis),
              ticker: analysis.ticker,
              tooltip: 'Guardar el hilo de la conversación en el Lab',
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(narrative, style: const TextStyle(fontSize: 13, height: 1.55)),
          const SizedBox(height: 10),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 13, color: AppTheme.neutral),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Texto redactado por IA sobre los números calculados arriba. Los números salen de '
                  'fórmulas; el texto es una interpretación y no una recomendación de inversión.',
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

/// La evolución de los períodos que trajo el backend.
///
/// Existe porque una foto de un solo período no distingue una empresa que mejora de una que empeora,
/// y esa es la pregunta que un diagnóstico contable tiene que poder contestar.
class _HistoryTable extends StatelessWidget {
  const _HistoryTable({required this.statements});

  final List<IncomeStatementBlock> statements;

  @override
  Widget build(BuildContext context) {
    return AnalysisCard(
      title: 'Evolución',
      icon: Icons.timeline_outlined,
      subtitle: 'Del período más reciente al más viejo',
      child: SingleChildScrollView(
        // La grilla scrollea sola en horizontal: con cinco períodos y cuatro columnas, forzarla al
        // ancho de un teléfono cortaría los números a la mitad.
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _HistoryRow(
              cells: ['Período', 'Ingresos', 'M. oper.', 'M. neto', 'EPS'],
              isHeader: true,
            ),
            for (final block in statements)
              _HistoryRow(
                cells: [
                  block.label,
                  _compactRevenue(block.revenue),
                  _pctCell(block.operatingMarginPct),
                  _pctCell(block.netMarginPct),
                  block.epsDiluted == null
                      ? kMissingValueLabel
                      : block.epsDiluted!.toStringAsFixed(2).replaceAll('.', ','),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.cells, this.isHeader = false});

  final List<String> cells;
  final bool isHeader;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          for (var index = 0; index < cells.length; index++)
            SizedBox(
              width: index == 0 ? 92 : 84,
              child: Text(
                cells[index],
                style: isHeader
                    ? const TextStyle(fontSize: 10, color: AppTheme.textMuted)
                    : AppTheme.numeric(fontSize: 11.5),
              ),
            ),
        ],
      ),
    );
  }
}

const String kMissingValueLabel = '—';

String _compactRevenue(double? value) {
  if (value == null) return kMissingValueLabel;
  final millions = value / 1e6;
  if (millions.abs() >= 1000) {
    return '${(millions / 1000).toStringAsFixed(1).replaceAll('.', ',')} MM';
  }
  return '${millions.toStringAsFixed(0)} M';
}

String _pctCell(double? value) {
  if (value == null) return kMissingValueLabel;
  return '${value.toStringAsFixed(1).replaceAll('.', ',')}%';
}

class _NeedsTicker extends StatelessWidget {
  const _NeedsTicker();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.science_outlined, size: 36, color: AppTheme.textMuted),
            SizedBox(height: 14),
            Text(
              'Elegí una empresa arriba para leer sus estados contables: márgenes, balance, caja, '
              'la descomposición del ROE y las banderas que se disparan.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textMuted, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnalysisError extends StatelessWidget {
  const _AnalysisError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Reintentar')),
          ],
        ),
      ),
    );
  }
}
