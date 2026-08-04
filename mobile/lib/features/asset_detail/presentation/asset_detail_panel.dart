import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/master_detail_layout.dart';
import 'asset_detail_screen.dart';
import 'selected_asset_controller.dart';

/// Panel derecho del master-detail: la Ficha del activo seleccionado, o un placeholder si
/// todavía no se eligió ninguno. Lo comparten la Watchlist y el Dashboard, que escriben en
/// `selectedAssetProvider`.
class AssetDetailPanel extends ConsumerWidget {
  const AssetDetailPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedAssetProvider);

    if (selected == null) {
      return const DetailPanelPlaceholder(
        message:
            'Elegí un activo de la lista para ver su Ficha de Inteligencia Profunda.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Cabecera propia del panel (no un AppBar): en escritorio el AppBar de la pantalla ya
        // está arriba de todo, y anidar otro se vería como dos barras apiladas.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  selected.ticker,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Cerrar',
                icon: const Icon(Icons.close),
                onPressed: () =>
                    ref.read(selectedAssetProvider.notifier).state = null,
              ),
            ],
          ),
        ),
        Expanded(
          child: AssetDetailView(
            // `key` por ticker: sin esto, Flutter reutiliza el State al cambiar de activo y el
            // toggle "Traductor Financiero" se quedaría en la posición del anterior.
            key: ValueKey(selected.ticker),
            ticker: selected.ticker,
            assetType: selected.assetType,
          ),
        ),
      ],
    );
  }
}
