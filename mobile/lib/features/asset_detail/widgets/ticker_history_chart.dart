import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../presentation/ticker_history_controller.dart';
import 'candlestick_chart_view.dart';

/// Sección de chart de la Ficha: consulta el histórico y lo dibuja, o explica por qué no hay.
///
/// El alto es fijo (260px) y se reserva en todos los estados — cargando, con datos, vacío y con
/// error — para que la Ficha no salte de layout cuando el histórico termina de llegar.
class TickerHistoryChart extends ConsumerWidget {
  const TickerHistoryChart({super.key, required this.ticker});

  final String ticker;

  static const double _height = 260;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(tickerHistoryProvider(ticker));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: _height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppTheme.surfaceSunken,
              borderRadius: BorderRadius.circular(AppTheme.radius),
              border: Border.all(color: AppTheme.border),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 16, 16, 4),
              child: historyAsync.when(
                data: (history) => history.isEmpty
                    ? _ChartNotice(
                        icon: Icons.candlestick_chart_outlined,
                        message: history.degradationReason ??
                            'No hay velas históricas para este rango.',
                      )
                    : CandlestickChartView(bars: history.bars),
                loading: () => const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
                // Un error acá es de red o de sesión: el endpoint devuelve 200 incluso cuando el
                // proveedor falla, así que este camino es raro y vale reintentarlo.
                error: (error, stackTrace) => _ChartNotice(
                  icon: Icons.cloud_off_outlined,
                  message: describeApiError(error),
                  onRetry: () => ref.invalidate(tickerHistoryProvider(ticker)),
                ),
              ),
            ),
          ),
        ),
        // La leyenda del rango solo se muestra cuando hay velas: sobre un chart vacío no hay nada
        // que contextualizar.
        if (historyAsync.valueOrNull?.isEmpty == false) ...[
          const SizedBox(height: 6),
          Text(
            'Últimos $kDefaultHistoryDays días · velas diarias · '
            '${historyAsync.value!.bars.length} ruedas',
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
          ),
        ],
      ],
    );
  }
}

class _ChartNotice extends StatelessWidget {
  const _ChartNotice({
    required this.icon,
    required this.message,
    this.onRetry,
  });

  final IconData icon;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: AppTheme.textMuted),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 8),
              TextButton(onPressed: onRetry, child: const Text('Reintentar')),
            ],
          ],
        ),
      ),
    );
  }
}
