import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../../watchlist/data/watchlist_models.dart';
import '../data/push_notification_payload.dart';
import '../widgets/deep_intelligence_sheet.dart';
import '../widgets/ticker_history_chart.dart';
import '../widgets/ticker_notes_tab.dart';
import 'asset_detail_controller.dart';

/// Pantalla 3 en mobile: la Ficha como pantalla completa, navegada por `/asset/:ticker`. En
/// escritorio el contenido se muestra en el panel derecho del master-detail sin navegar — ahí
/// se usa `AssetDetailView` directo (ver `watchlist_screen.dart`), que es el mismo cuerpo sin
/// Scaffold ni AppBar propios.
class AssetDetailScreen extends StatelessWidget {
  const AssetDetailScreen(
      {super.key, required this.ticker, required this.assetType});

  final String ticker;
  final AssetType assetType;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(ticker)),
      body: AssetDetailView(ticker: ticker, assetType: assetType),
    );
  }
}

/// Detalle de un activo, sin cromo propio (ni Scaffold ni AppBar) para poder usarse tanto como
/// pantalla completa (mobile) como panel lateral (escritorio).
///
/// Tres pestañas, con fuentes de datos INDEPENDIENTES:
///
///   - **Resumen** — la alerta del agente (`GET /api/v1/assets/{ticker}` on-demand más el
///     WebSocket en vivo) y el chart de velas (`GET /api/v1/market/history/{ticker}`).
///   - **Inteligencia Profunda** — fundamentales, síntesis de reportes y proyecciones por horizonte
///     (`GET /api/v1/tickers/{ticker}/intelligence`).
///   - **Notas** — las notas del Investment Lab vinculadas a este símbolo
///     (`GET /api/v1/notes?ticker=`). Es lo único de las tres que el usuario escribió, y por eso es
///     lo único que no se puede regenerar.
///
/// Las pestañas están ARRIBA del gate del payload de alertas a propósito. El cuerpo de "Resumen"
/// no se puede dibujar sin ese payload, pero la Inteligencia Profunda no lo necesita: si estuviera
/// anidada dentro, un motor de alertas sin credenciales la dejaría inalcanzable aunque su propio
/// endpoint esté respondiendo perfecto.
class AssetDetailView extends ConsumerStatefulWidget {
  const AssetDetailView(
      {super.key, required this.ticker, required this.assetType});

  final String ticker;
  final AssetType assetType;

  @override
  ConsumerState<AssetDetailView> createState() => _AssetDetailViewState();
}

class _AssetDetailViewState extends ConsumerState<AssetDetailView>
    with SingleTickerProviderStateMixin {
  bool? _showBeginnerOverride;
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          // `isScrollable` con tres pestañas: en el panel angosto del master-detail, tres etiquetas
          // de ancho fijo cortan "Inteligencia Profunda" a la mitad.
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'Resumen', icon: Icon(Icons.insights_outlined, size: 18)),
            Tab(
              text: 'Inteligencia Profunda',
              icon: Icon(Icons.travel_explore_outlined, size: 18),
            ),
            Tab(text: 'Notas', icon: Icon(Icons.edit_note_outlined, size: 18)),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _OverviewTab(
                ticker: widget.ticker,
                assetType: widget.assetType,
                showBeginnerOverride: _showBeginnerOverride,
                onToggleBeginner: (value) =>
                    setState(() => _showBeginnerOverride = value),
              ),
              DeepIntelligenceSheet(ticker: widget.ticker),
              TickerNotesTab(ticker: widget.ticker),
            ],
          ),
        ),
      ],
    );
  }
}

/// Pestaña "Resumen": la alerta del agente más el chart. Es el cuerpo que antes era todo
/// `AssetDetailView`, extraído tal cual para que la pestaña de Inteligencia Profunda no herede su
/// dependencia del payload.
class _OverviewTab extends ConsumerWidget {
  const _OverviewTab({
    required this.ticker,
    required this.assetType,
    required this.showBeginnerOverride,
    required this.onToggleBeginner,
  });

  final String ticker;
  final AssetType assetType;
  final bool? showBeginnerOverride;
  final ValueChanged<bool> onToggleBeginner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (ticker, assetType);
    final liveAsync = ref.watch(tickerPayloadProvider(ticker));
    final onDemandAsync = ref.watch(assetIntelligenceProvider(args));

    final effectivePayload = liveAsync.valueOrNull ?? onDemandAsync.valueOrNull;

    return effectivePayload != null
        ? _AssetDetailBody(
            payload: effectivePayload,
            showBeginner:
                showBeginnerOverride ?? effectivePayload.defaultViewIsBeginner,
            onToggleBeginner: onToggleBeginner,
          )
        : onDemandAsync.when(
            // `data` solo se ejecuta acá si `effectivePayload` fue null a pesar de tener
            // datos, lo cual no debería pasar (`valueOrNull` ya lo hubiese devuelto arriba)
            // — placeholder defensivo, no un camino real.
            data: (_) => const SizedBox.shrink(),
            loading: () => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text('Analizando $ticker…', textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
            error: (error, stackTrace) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(describeApiError(error), textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () =>
                          ref.invalidate(assetIntelligenceProvider(args)),
                      child: const Text('Reintentar'),
                    ),
                  ],
                ),
              ),
            ),
          );
  }
}

class _AssetDetailBody extends StatelessWidget {
  const _AssetDetailBody({
    required this.payload,
    required this.showBeginner,
    required this.onToggleBeginner,
  });

  final PushNotificationPayload payload;
  final bool showBeginner;
  final ValueChanged<bool> onToggleBeginner;

  @override
  Widget build(BuildContext context) {
    final narrative =
        showBeginner ? payload.beginnerNarrative : payload.technicalNarrative;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _UrgencyBadge(urgency: payload.urgencyLevel),
            Row(
              children: [
                const Text('Traductor Financiero'),
                Switch(value: showBeginner, onChanged: onToggleBeginner),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        TickerHistoryChart(ticker: payload.ticker),
        const SizedBox(height: 20),
        Text(narrative.headline, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        for (final explanation in narrative.horizonExplanations)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('• $explanation'),
          ),
        if (payload.fullAnalysis != null) ...[
          const SizedBox(height: 20),
          Text('Proyección por horizonte',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final horizon in payload.fullAnalysis!.horizons)
            _HorizonCard(horizon: horizon),
        ],
      ],
    );
  }
}

class _UrgencyBadge extends StatelessWidget {
  const _UrgencyBadge({required this.urgency});

  final AlertUrgency urgency;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (urgency) {
      AlertUrgency.low => ('BAJA', AppTheme.textMuted),
      AlertUrgency.medium => ('MEDIA', AppTheme.neutral),
      AlertUrgency.high => ('ALTA', AppTheme.bearish),
      AlertUrgency.critical => ('CRÍTICA', AppTheme.bearish),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: AppTheme.badgeDecoration(color),
      child: Text(
        label,
        style: AppTheme.numeric(
          fontSize: 11,
          color: color,
        ).copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _HorizonCard extends StatelessWidget {
  const _HorizonCard({required this.horizon});

  final HorizonScenarios horizon;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              horizon.horizon.displayLabel,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              'Confianza: ${horizon.confidenceLevel}',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 8),
            for (final scenario in horizon.scenarios)
              _ScenarioBar(scenario: scenario),
          ],
        ),
      ),
    );
  }
}

class _ScenarioBar extends StatelessWidget {
  const _ScenarioBar({required this.scenario});

  final ScenarioOutcome scenario;

  @override
  Widget build(BuildContext context) {
    final color = switch (scenario.label) {
      ScenarioLabel.alcista => AppTheme.bullish,
      ScenarioLabel.neutral => AppTheme.neutral,
      ScenarioLabel.bajista => AppTheme.bearish,
    };
    final label = switch (scenario.label) {
      ScenarioLabel.alcista => 'Alcista',
      ScenarioLabel.neutral => 'Neutral',
      ScenarioLabel.bajista => 'Bajista',
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(fontSize: 13)),
              // Probabilidad en monoespaciada: las tres barras (alcista/neutral/bajista)
              // quedan una debajo de otra, y con ancho fijo por dígito los porcentajes
              // alinean y se comparan de un vistazo.
              Text(
                '${scenario.probabilityPct.toStringAsFixed(0)}%',
                style: AppTheme.numeric(color: color),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: scenario.probabilityPct / 100,
              color: color,
              backgroundColor: AppTheme.surfaceSunken,
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }
}
