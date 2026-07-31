import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../data/push_notification_payload.dart';
import '../widgets/lightweight_chart_view.dart';
import 'asset_detail_controller.dart';

/// Pantalla 3: Ficha de Inteligencia Profunda de un activo.
///
/// TODO(backend): hoy no existe un `GET /api/v1/assets/{ticker}` para pedir el análisis "on
/// demand" — esta pantalla solo recibe datos cuando el motor despacha una alerta nueva para
/// `ticker` (vía `WS /api/v1/ws/{ticker}`, ver `app/api/v1/websocket.py`), así que al entrar
/// puede quedar "esperando" hasta la próxima corrida del scheduler. Un endpoint de lectura
/// bajo demanda (reusando `AgentRunnerService._run_single_ticker`) es el próximo paso natural.
/// El chart tampoco tiene todavía una fuente de velas históricas — se ve con datos de ejemplo,
/// marcados explícitamente, hasta que exista ese endpoint.
class AssetDetailScreen extends ConsumerStatefulWidget {
  const AssetDetailScreen({super.key, required this.ticker});

  final String ticker;

  @override
  ConsumerState<AssetDetailScreen> createState() => _AssetDetailScreenState();
}

class _AssetDetailScreenState extends ConsumerState<AssetDetailScreen> {
  bool? _showBeginnerOverride;

  @override
  Widget build(BuildContext context) {
    final payloadAsync = ref.watch(tickerPayloadProvider(widget.ticker));

    return Scaffold(
      appBar: AppBar(title: Text(widget.ticker)),
      body: payloadAsync.when(
        data: (payload) => _AssetDetailBody(
          payload: payload,
          showBeginner: _showBeginnerOverride ?? payload.defaultViewIsBeginner,
          onToggleBeginner: (value) => setState(() => _showBeginnerOverride = value),
        ),
        loading: () => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  'Esperando la próxima actualización en vivo de ${widget.ticker}…',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
        error: (error, _) => Center(child: Text('No se pudo conectar: $error')),
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
