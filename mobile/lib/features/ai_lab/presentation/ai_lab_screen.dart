import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../tickers/presentation/ticker_search_field.dart';
import '../data/ai_lab_models.dart';
import '../widgets/financial_analysis_tab.dart';
import '../widgets/scenario_simulator_tab.dart';
import 'ai_lab_controller.dart';

/// Laboratorio Financiero: análisis contable conversacional y simulador de escenarios.
///
/// Es una pantalla NAVEGADA (`/ai-lab/:ticker`) y no un destino de la barra por dos razones. La
/// primera es de foco: el Laboratorio siempre se abre sobre una empresa concreta, y llega desde la
/// ficha del activo o desde una búsqueda. La segunda es de espacio: con cinco destinos la barra
/// inferior ya está llena en un teléfono, y un sexto convertiría todas las etiquetas en abreviaturas.
///
/// El símbolo y la periodicidad son COMPARTIDOS por las dos pestañas: quien vio que una empresa tiene
/// la deuda alta y pasa al simulador a subirle la tasa está siguiendo la misma pregunta, y hacerle
/// elegir la empresa dos veces rompe ese hilo.
class AiLabScreen extends ConsumerStatefulWidget {
  const AiLabScreen({super.key, this.ticker});

  /// El símbolo con el que se abre. `null` deja la pantalla esperando una búsqueda.
  final String? ticker;

  @override
  ConsumerState<AiLabScreen> createState() => _AiLabScreenState();
}

class _AiLabScreenState extends ConsumerState<AiLabScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    final incoming = widget.ticker?.trim().toUpperCase();
    if (incoming != null && incoming.isNotEmpty) {
      // El estado se toca después del primer frame: escribir en un provider durante `initState`
      // dispara el assert de Riverpod por modificar el árbol mientras se está construyendo.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _selectTicker(incoming);
      });
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _selectTicker(String symbol) {
    ref.read(aiLabTickerProvider.notifier).state = symbol;
    // Cambiar de empresa descarta la simulación anterior: dejarla en pantalla junto al nombre nuevo
    // haría leer los números de una empresa como si fueran de otra, que es el peor error posible acá.
    ref.read(simulationControllerProvider.notifier).reset();
    ref.read(scenarioVariablesProvider.notifier).reset();
    ref.read(analysisControllerProvider.notifier).load(symbol);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Laboratorio Financiero'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(
              text: 'Análisis contable',
              icon: Icon(Icons.analytics_outlined, size: 18),
            ),
            Tab(
              text: 'Simulador',
              icon: Icon(Icons.tune_outlined, size: 18),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          _AiLabToolbar(onSelected: _selectTicker),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: const [FinancialAnalysisTab(), ScenarioSimulatorTab()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Barra con la empresa elegida y la periodicidad.
class _AiLabToolbar extends ConsumerWidget {
  const _AiLabToolbar({required this.onSelected});

  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ticker = ref.watch(aiLabTickerProvider);
    final period = ref.watch(aiLabPeriodProvider);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.science_outlined, size: 16, color: AppTheme.accent),
              const SizedBox(width: 8),
              if (ticker == null)
                const Text(
                  'Ninguna empresa elegida',
                  style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                )
              else
                Text(ticker, style: AppTheme.tickerSymbol.copyWith(fontSize: 15)),
            ],
          ),
          OutlinedButton.icon(
            onPressed: () => AiLabTickerDialog.show(context, onSelected),
            icon: const Icon(Icons.search, size: 15),
            label: Text(
              ticker == null ? 'Elegir empresa' : 'Cambiar',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          SegmentedButton<StatementPeriod>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            segments: [
              for (final option in StatementPeriod.values)
                ButtonSegment(
                  value: option,
                  label: Text(
                    statementPeriodLabel(option),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
            ],
            selected: {period},
            onSelectionChanged: (selection) {
              final next = selection.first;
              if (next == period) return;
              ref.read(aiLabPeriodProvider.notifier).state = next;
              // Cambiar la periodicidad invalida las dos vistas: un margen trimestral y uno anual no
              // se comparan, y una simulación corrida sobre un trimestre no describe el año.
              ref.read(simulationControllerProvider.notifier).reset();
              final current = ref.read(aiLabTickerProvider);
              if (current != null) {
                ref
                    .read(analysisControllerProvider.notifier)
                    .load(current, force: true);
              }
            },
          ),
        ],
      ),
    );
  }
}

/// El diálogo de búsqueda del símbolo.
///
/// Se busca sobre el catálogo local y no se acepta texto libre: un símbolo inexistente devolvería un
/// diagnóstico vacío indistinguible de "esta empresa no publica estados", que es exactamente la
/// ambigüedad que el módulo se ocupa de evitar.
class AiLabTickerDialog extends StatelessWidget {
  const AiLabTickerDialog({super.key, required this.onSelected});

  final ValueChanged<String> onSelected;

  static Future<void> show(
    BuildContext context,
    ValueChanged<String> onSelected,
  ) {
    return showDialog<void>(
      context: context,
      builder: (_) => AiLabTickerDialog(onSelected: onSelected),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Elegir empresa'),
      content: SizedBox(
        width: 380,
        child: TickerSearchField(
          onSelected: (ticker) {
            onSelected(ticker.symbol);
            Navigator.of(context).pop();
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}
