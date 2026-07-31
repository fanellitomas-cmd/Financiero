import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../data/watchlist_models.dart';
import 'watchlist_controller.dart';

/// Pantalla 4: Gestión de Watchlist. El "Centro de Notificaciones Nativas" (historial de
/// alertas ya disparadas) queda pendiente: `AlertHistory` existe en la DB
/// (`app/models/alert_history.py`) pero todavía no hay un `GET /api/v1/alerts` que lo
/// exponga al usuario — solo se persiste internamente desde `/internal/trigger-agent`. Es el
/// próximo endpoint a agregar del lado del backend para completar esta pantalla.
class WatchlistScreen extends ConsumerWidget {
  const WatchlistScreen({super.key});

  Future<void> _showAddDialog(BuildContext context, WidgetRef ref) async {
    final tickerController = TextEditingController();
    var assetType = AssetType.stock;

    final added = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Agregar a la watchlist'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: tickerController,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Ticker (ej: NVDA, BTC-USD)'),
              ),
              const SizedBox(height: 12),
              SegmentedButton<AssetType>(
                segments: const [
                  ButtonSegment(value: AssetType.stock, label: Text('Acción')),
                  ButtonSegment(value: AssetType.crypto, label: Text('Cripto')),
                ],
                selected: {assetType},
                onSelectionChanged: (selection) =>
                    setDialogState(() => assetType = selection.first),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () async {
                final ticker = tickerController.text.trim();
                if (ticker.isEmpty) return;
                await ref
                    .read(watchlistRepositoryProvider)
                    .add(ticker: ticker, assetType: assetType);
                if (dialogContext.mounted) Navigator.of(dialogContext).pop(true);
              },
              child: const Text('Agregar'),
            ),
          ],
        ),
      ),
    );

    if (added ?? false) {
      ref.invalidate(watchlistProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watchlistAsync = ref.watch(watchlistProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Mi Watchlist')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddDialog(context, ref),
        child: const Icon(Icons.add),
      ),
      body: watchlistAsync.when(
        data: (items) => items.isEmpty
            ? const Center(child: Text('Agregá tu primer ticker con el botón +'))
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(watchlistProvider),
                child: ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ListTile(
                      title: Text(item.ticker),
                      subtitle: Text(
                        '${item.assetType == AssetType.stock ? "Acción" : "Cripto"} · '
                        'alerta a ±${item.alertThresholdPct}%'
                        '${item.enableBeginnerMode ? " · modo principiante" : ""}',
                      ),
                      onTap: () => context.push('/asset/${item.ticker}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await ref.read(watchlistRepositoryProvider).remove(item.id);
                          ref.invalidate(watchlistProvider);
                        },
                      ),
                    );
                  },
                ),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('No se pudo cargar: $error')),
      ),
    );
  }
}
