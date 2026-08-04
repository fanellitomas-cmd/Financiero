import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../../settings/presentation/exchange_selector.dart';
import '../../watchlist/data/watchlist_models.dart';
import '../../watchlist/presentation/watchlist_controller.dart';
import '../data/market_quote.dart';
import 'market_quotes_controller.dart';

/// Pantalla 1: Home / Dashboard Macro. Heatmap de la Watchlist (con precio/%var en vivo de
/// `GET /api/v1/market/quotes`) + Daily Digest del agente.
///
/// TODO(backend): el Daily Digest todavía no tiene un endpoint propio — no hay un concepto de
/// "resumen generado por el agente" expuesto en `app/api/v1/` todavía. El heatmap sí es real:
/// usa la Watchlist para saber qué tickers mostrar y `/market/quotes` para el precio/%var,
/// degradando tile-por-tile (no toda la pantalla) si un proveedor falla para un ticker puntual.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watchlistAsync = ref.watch(watchlistProvider);
    final quotesAsync = ref.watch(marketQuotesProvider);

    final quotes = quotesAsync.valueOrNull;
    final quotesByTicker = <String, TickerQuote>{
      if (quotes != null) for (final quote in quotes) quote.ticker: quote,
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('Financiero'),
        actions: const [ExchangeSelector()],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(watchlistProvider);
          ref.invalidate(marketQuotesProvider);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _DailyDigestCard(),
            const SizedBox(height: 24),
            Text('Watchlist', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            watchlistAsync.when(
              data: (items) => items.isEmpty
                  ? const Text('Todavía no seguís ningún activo.')
                  : _HeatmapGrid(items: items, quotesByTicker: quotesByTicker),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stackTrace) => Text(describeApiError(error)),
            ),
            if (quotesAsync.hasError) ...[
              const SizedBox(height: 8),
              Text(
                'Precios en vivo: ${describeApiError(quotesAsync.error!)}',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DailyDigestCard extends StatelessWidget {
  const _DailyDigestCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Resumen del día', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'El Daily Digest generado por el agente todavía no tiene un endpoint en el '
              'backend — placeholder hasta que se agregue.',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeatmapGrid extends StatelessWidget {
  const _HeatmapGrid({required this.items, required this.quotesByTicker});

  final List<WatchlistItem> items;
  final Map<String, TickerQuote> quotesByTicker;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1.1,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return _HeatmapTile(item: item, quote: quotesByTicker[item.ticker]);
      },
    );
  }
}

class _HeatmapTile extends StatelessWidget {
  const _HeatmapTile({required this.item, required this.quote});

  final WatchlistItem item;
  final TickerQuote? quote;

  @override
  Widget build(BuildContext context) {
    final hasValidQuote = quote != null && quote!.status == QuoteStatus.ok;
    final changePct = hasValidQuote ? quote!.dayChangePct : null;

    final color = changePct == null
        ? Colors.grey
        : changePct >= 0
            ? AppTheme.bullish
            : AppTheme.bearish;

    final label = changePct == null
        ? '—'
        : '${changePct >= 0 ? '+' : ''}${changePct.toStringAsFixed(2)}%';

    return InkWell(
      onTap: () => context.push('/asset/${item.ticker}?assetType=${item.assetType.toJson()}'),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(item.ticker, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: color, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
