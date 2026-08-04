import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_error.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/widgets/master_detail_layout.dart';
import '../../asset_detail/presentation/asset_detail_panel.dart';
import '../../asset_detail/presentation/selected_asset_controller.dart';
import '../../settings/data/exchange_type.dart';
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
    final selectedExchange = ref.watch(selectedExchangeProvider);

    final quotes = quotesAsync.valueOrNull;
    final quotesByTicker = <String, TickerQuote>{
      if (quotes != null)
        for (final quote in quotes) quote.ticker: quote,
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('Financiero'),
        actions: const [ExchangeSelector()],
      ),
      body: MasterDetailLayout(
        master: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(watchlistProvider);
            ref.invalidate(marketQuotesProvider);
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const _DailyDigestCard(),
              const SizedBox(height: 24),
              Text(
                // El título nombra la bolsa activa: el heatmap está filtrado por ella
                // (`watchlistProvider` observa `selectedExchangeProvider`), y sin decirlo
                // parecería que faltan activos.
                selectedExchange == null
                    ? 'Watchlist'
                    : 'Watchlist · ${selectedExchange.displayName}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              watchlistAsync.when(
                data: (items) => items.isEmpty
                    ? Text(
                        selectedExchange == null
                            ? 'Todavía no seguís ningún activo.'
                            : 'No seguís ningún activo de '
                                '${selectedExchange.displayName}.',
                        style: const TextStyle(color: Colors.grey),
                      )
                    : _HeatmapGrid(
                        items: items, quotesByTicker: quotesByTicker),
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
        detail: const AssetDetailPanel(),
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
            Text('Resumen del día',
                style: Theme.of(context).textTheme.titleMedium),
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
    // Columnas según el ancho REAL disponible, no según el de la ventana: en master-detail
    // este grid vive en un panel de 380px aunque la ventana tenga 1900, así que mirar
    // `MediaQuery` daría demasiadas columnas y los tiles quedarían ilegibles.
    return LayoutBuilder(
      builder: (context, constraints) {
        const targetTileWidth = 120.0;
        final columns =
            (constraints.maxWidth / targetTileWidth).floor().clamp(2, 8);

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
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
      },
    );
  }
}

class _HeatmapTile extends ConsumerWidget {
  const _HeatmapTile({required this.item, required this.quote});

  final WatchlistItem item;
  final TickerQuote? quote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      onTap: () {
        // Mismo criterio que la Watchlist: en escritorio llena el panel derecho, en mobile
        // navega a la ficha completa.
        if (context.isMasterDetail) {
          ref.read(selectedAssetProvider.notifier).state =
              SelectedAsset(ticker: item.ticker, assetType: item.assetType);
          return;
        }
        context
            .push('/asset/${item.ticker}?assetType=${item.assetType.toJson()}');
      },
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
            Text(item.ticker,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: color, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
