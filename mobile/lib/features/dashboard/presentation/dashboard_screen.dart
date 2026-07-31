import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../watchlist/data/watchlist_models.dart';
import '../../watchlist/presentation/watchlist_controller.dart';

/// Pantalla 1: Home / Dashboard Macro. Heatmap de la Watchlist + Daily Digest del agente.
///
/// TODO(backend): el heatmap necesita el % de variación en vivo de cada ticker y el Daily
/// Digest necesita un resumen generado por el agente — ninguno de los dos tiene todavía un
/// endpoint de lectura en `app/api/v1/` (solo existe el pipeline interno de
/// `/internal/trigger-agent`, que persiste en `AlertHistory` pero no se expone al usuario).
/// Por ahora esta pantalla arma el layout real con la Watchlist como fuente de los tickers a
/// mostrar, y placeholders explícitos donde falta el dato — no datos inventados.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watchlistAsync = ref.watch(watchlistProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Financiero')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(watchlistProvider),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _DailyDigestCard(),
            const SizedBox(height: 24),
            Text('Watchlist', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            watchlistAsync.when(
              data: (items) => items.isEmpty
                  ? const Text('Todavía no seguís ningún activo.')
                  : _HeatmapGrid(items: items),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Text('No se pudo cargar la watchlist: $error'),
            ),
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
  const _HeatmapGrid({required this.items});

  final List<WatchlistItem> items;

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
        return _HeatmapTile(item: item);
      },
    );
  }
}

class _HeatmapTile extends StatelessWidget {
  const _HeatmapTile({required this.item});

  final WatchlistItem item;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.push('/asset/${item.ticker}'),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.neutral.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.neutral.withOpacity(0.4)),
        ),
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              item.ticker,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text('—', style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
