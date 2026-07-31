import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../../watchlist/data/watchlist_models.dart';
import '../data/push_notification_payload.dart';
import '../widgets/lightweight_chart_view.dart';
import 'asset_detail_controller.dart';

/// Pantalla 3: Ficha de Inteligencia Profunda de un activo. Combina dos fuentes: un fetch
/// on-demand contra `GET /api/v1/assets/{ticker}` al abrir la pantalla (`assetIntelligenceProvider`,
/// para no depender de esperar la próxima corrida del scheduler) y el WebSocket en vivo
/// (`tickerPayloadProvider`, para reflejar al toque una alerta nueva mientras la pantalla ya
/// está abierta). El WS tiene prioridad cuando ambos tienen datos.
///
/// El chart todavía no tiene una fuente de velas históricas real — se ve con datos de
/// ejemplo, marcados explícitamente en la UI, hasta que el backend exponga ese endpoint.
class AssetDetailScreen extends ConsumerStatefulWidget {
  const AssetDetailScreen({super.key, required this.ticker, required this.assetType});

  final String ticker;
  final AssetType assetType;

  @override
  ConsumerState<AssetDetailScreen> createState() => _AssetDetailScreenState();
}

class _AssetDetailScreenState extends ConsumerState<AssetDetailScreen> {
  bool? _showBeginnerOverride;

  @override
  Widget build(BuildContext context) {
    final args = (widget.ticker, widget.assetType);
    final liveAsync = ref.watch(tickerPayloadProvider(widget.ticker));
    final onDemandAsync = ref.watch(assetIntelligenceProvider(args));

    final effectivePayload = liveAsync.valueOrNull ?? onDemandAsync.valueOrNull;

    return Scaffold(
      appBar: AppBar(title: Text(widget.ticker)),
      body: effectivePayload != null
          ? _AssetDetailBody(
              payload: effectivePayload,
              showBeginner: _showBeginnerOverride ?? effectivePayload.defaultViewIsBeginner,
              onToggleBeginner: (value) => setState(() => _showBeginnerOverride = value),
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
                      Text('Analizando ${widget.ticker}…', textAlign: TextAlign.center),
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
                        onPressed: () => ref.invalidate(assetIntelligenceProvider(args)),
                        child: const Text('Reintentar'),
                      ),
                    ],
                  ),
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

  static const _sampleCandles = [
    Candle(time: 1706227200, open: 100, high: 104, low: 98, close: 102),
    Candle(time: 1706313600, open: 102, high: 108, low: 101, close: 106),
    Candle(time: 1706400000, open: 106, high: 107, low: 99, close: 101),
    Candle(time: 1706486400, open: 101, high: 110, low: 100, close: 109),
  ];

  @override
  Widget build(BuildContext context) {
    final narrative = showBeginner ? payload.beginnerNarrative : payload.technicalNarrative;

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
        SizedBox(
          height: 260,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: const LightweightChartView(candles: _sampleCandles),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Datos de ejemplo — falta el endpoint de velas históricas (ver TODO arriba).',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
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
          Text('Proyección por horizonte', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final horizon in payload.fullAnalysis!.horizons) _HorizonCard(horizon: horizon),
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
      AlertUrgency.low => ('BAJA', Colors.grey),
      AlertUrgency.medium => ('MEDIA', AppTheme.neutral),
      AlertUrgency.high => ('ALTA', AppTheme.bearish),
      AlertUrgency.critical => ('CRÍTICA', AppTheme.bearish),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color),
      ),
      child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
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
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 8),
            for (final scenario in horizon.scenarios) _ScenarioBar(scenario: scenario),
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
          Text('$label · ${scenario.probabilityPct.toStringAsFixed(0)}%'),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: scenario.probabilityPct / 100,
              color: color,
              backgroundColor: color.withOpacity(0.15),
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }
}
