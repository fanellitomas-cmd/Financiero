import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../data/market_summary.dart';
import '../presentation/market_summary_controller.dart';

/// Card del Resumen Diario, arriba del Dashboard: narrativa del agente + chips de mayores subas
/// y bajas de la jornada.
///
/// La regla que gobierna el diseño: **mostrar lo que hay y decir qué falta**. El backend degrada
/// la narrativa y los datos de mercado por separado (`app/services/market_summary_service.py`),
/// así que hay cuatro estados reales que la card tiene que servir sin esconderse:
///   1. Todo OK → narrativa + chip de sentimiento + puntos clave + movers.
///   2. Movers sin narrativa (Gemini no configurado o caído) → movers + el motivo, en tono de
///      aviso, no de error.
///   3. Sin datos de mercado → solo el motivo.
///   4. El request falló (503, red) → el error, con opción de reintentar.
class MarketSummaryCard extends ConsumerWidget {
  const MarketSummaryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(marketSummaryProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: summaryAsync.when(
          data: (summary) => _SummaryContent(summary: summary),
          loading: () => const _SummaryLoading(),
          error: (error, stackTrace) => _SummaryError(
            message: describeApiError(error),
            onRetry: () => ref.invalidate(marketSummaryProvider),
          ),
        ),
      ),
    );
  }
}

class _CardHeader extends StatelessWidget {
  const _CardHeader({this.trailing});

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            'Resumen del día',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _SummaryLoading extends StatelessWidget {
  const _SummaryLoading();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _CardHeader(),
        const SizedBox(height: 16),
        Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text(
              'Compilando el resumen de la jornada…',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textMuted,
                  ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SummaryError extends StatelessWidget {
  const _SummaryError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _CardHeader(),
        const SizedBox(height: 8),
        Text(
          message,
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child:
              TextButton(onPressed: onRetry, child: const Text('Reintentar')),
        ),
      ],
    );
  }
}

class _SummaryContent extends StatelessWidget {
  const _SummaryContent({required this.summary});

  final MarketSummary summary;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CardHeader(
          trailing: summary.sentiment?.label != null
              ? _SentimentBadge(sentiment: summary.sentiment!)
              : null,
        ),
        if (summary.headline != null) ...[
          const SizedBox(height: 12),
          Text(summary.headline!,
              style: Theme.of(context).textTheme.titleSmall),
        ],
        if (summary.keyPoints.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final point in summary.keyPoints)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '• $point',
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
              ),
            ),
        ],
        // El motivo de la degradación va DESPUÉS de la narrativa (cuando hay) y antes de los
        // movers: explica qué falta sin tapar lo que sí llegó.
        if (summary.degradationReason != null) ...[
          const SizedBox(height: 12),
          _DegradationNotice(reason: summary.degradationReason!),
        ],
        if (summary.topGainers.isNotEmpty || summary.topLosers.isNotEmpty) ...[
          const SizedBox(height: 16),
          _MoversSection(
            label: 'Mayores subas',
            movers: summary.topGainers,
            color: AppTheme.bullish,
            icon: Icons.trending_up,
          ),
          if (summary.topLosers.isNotEmpty) ...[
            const SizedBox(height: 12),
            _MoversSection(
              label: 'Mayores bajas',
              movers: summary.topLosers,
              color: AppTheme.bearish,
              icon: Icons.trending_down,
            ),
          ],
        ],
        if (summary.isEmpty && summary.degradationReason == null) ...[
          const SizedBox(height: 8),
          const Text(
            'Todavía no hay datos de la jornada.',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

/// Chip de sentimiento con código de color. Verde y rojo son los mismos tokens que usa el resto
/// de la app para dirección de mercado; el neutral va en cian (el color de acento) porque el
/// ámbar de `AppTheme.neutral` se lee como advertencia y "mercado lateral" no es una advertencia.
class _SentimentBadge extends StatelessWidget {
  const _SentimentBadge({required this.sentiment});

  final MarketSentiment sentiment;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (sentiment.label) {
      MarketSentimentLabel.alcista => ('ALCISTA', AppTheme.bullish),
      MarketSentimentLabel.bajista => ('BAJISTA', AppTheme.bearish),
      MarketSentimentLabel.neutral => ('NEUTRAL', AppTheme.accent),
      // El llamador ya verificó que `label != null`; esta rama existe para que el switch sea
      // exhaustivo sin un `!` que se rompa en silencio si eso cambia.
      null => ('SIN DATO', AppTheme.textMuted),
    };

    final confidence = sentiment.confidencePct;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: AppTheme.badgeDecoration(color),
      child: Text(
        confidence == null
            ? label
            : '$label · ${confidence.toStringAsFixed(0)}%',
        style: AppTheme.numeric(
          fontSize: 11,
          color: color,
        ).copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// Aviso de degradación: por qué falta una parte del resumen. Ámbar y no rojo a propósito — que
/// el agente no esté configurado no es un fallo de la app, y pintarlo de rojo haría que un
/// entorno sin credenciales pareciera roto.
class _DegradationNotice extends StatelessWidget {
  const _DegradationNotice({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.neutral.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.neutral.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 16, color: AppTheme.neutral),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              reason,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _MoversSection extends StatelessWidget {
  const _MoversSection({
    required this.label,
    required this.movers,
    required this.color,
    required this.icon,
  });

  final String label;
  final List<MarketMover> movers;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (movers.isEmpty)
          const Text(
            'Sin datos.',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
          )
        else
          // `Wrap` y no una fila con scroll: en el panel de 380px del master-detail los chips
          // bajan de línea solos, y en una ventana ancha entran todos en una.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final mover in movers)
                _MoverChip(mover: mover, color: color),
            ],
          ),
      ],
    );
  }
}

class _MoverChip extends StatelessWidget {
  const _MoverChip({required this.mover, required this.color});

  final MarketMover mover;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final change = mover.dayChangePct;
    // Sin variación el chip se pinta neutro: teñirlo del color de la sección afirmaría una
    // dirección que no se tiene.
    final effectiveColor = change == null ? AppTheme.textMuted : color;
    final changeLabel = change == null
        ? '—'
        : '${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}%';

    return Tooltip(
      // El nombre de la empresa no entra en el chip, pero es lo que hace reconocible al símbolo.
      message: mover.name ?? mover.ticker,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Color.alphaBlend(
            effectiveColor.withValues(alpha: 0.12),
            AppTheme.surfaceSunken,
          ),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: effectiveColor.withValues(alpha: 0.40),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              mover.ticker,
              style: AppTheme.tickerSymbol.copyWith(fontSize: 12),
            ),
            const SizedBox(width: 8),
            Text(
              changeLabel,
              style: AppTheme.numeric(fontSize: 12, color: effectiveColor),
            ),
          ],
        ),
      ),
    );
  }
}
