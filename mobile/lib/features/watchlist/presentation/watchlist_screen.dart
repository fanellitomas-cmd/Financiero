import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_error.dart';
import '../../../core/providers.dart';
import '../data/watchlist_models.dart';
import 'watchlist_controller.dart';

/// Pantalla 4: Gestión de Watchlist. El Centro de Notificaciones (historial de alertas ya
/// disparadas) es una pantalla separada (`features/alerts/`), a la que se llega desde el
/// ícono de campana del AppBar acá abajo.
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

  Future<void> _showEditDialog(
    BuildContext context,
    WidgetRef ref,
    WatchlistItem item,
  ) async {
    final thresholdController = TextEditingController(
      text: item.alertThresholdPct.toString(),
    );
    var enableBeginnerMode = item.enableBeginnerMode;
    String? errorText;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('Editar ${item.ticker}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: thresholdController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Umbral de alerta (%)',
                  errorText: errorText,
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Modo principiante'),
                value: enableBeginnerMode,
                onChanged: (value) => setDialogState(() => enableBeginnerMode = value),
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
                final threshold = double.tryParse(thresholdController.text.trim());
                if (threshold == null || threshold <= 0 || threshold > 100) {
                  setDialogState(() => errorText = 'Ingresá un número entre 0 y 100.');
                  return;
                }
                try {
                  await ref.read(watchlistRepositoryProvider).update(
                        item.id,
                        alertThresholdPct: threshold,
                        enableBeginnerMode: enableBeginnerMode,
                      );
                  if (dialogContext.mounted) Navigator.of(dialogContext).pop(true);
                } on Object catch (error) {
                  setDialogState(() => errorText = describeApiError(error));
                }
              },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );

    if (saved ?? false) {
      ref.invalidate(watchlistProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watchlistAsync = ref.watch(watchlistProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mi Watchlist'),
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_outlined),
            tooltip: 'Notificaciones',
            onPressed: () => context.push('/alerts'),
          ),
        ],
      ),
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
                      onTap: () => context.push(
                        '/asset/${item.ticker}?assetType=${item.assetType.toJson()}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _showEditDialog(context, ref, item),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              await ref.read(watchlistRepositoryProvider).remove(item.id);
                              ref.invalidate(watchlistProvider);
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(child: Text(describeApiError(error))),
      ),
    );
  }
}
