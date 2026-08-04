import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../watchlist/data/watchlist_models.dart';

/// Qué activo está abierto en el panel derecho del master-detail (escritorio).
@immutable
class SelectedAsset {
  const SelectedAsset({required this.ticker, required this.assetType});

  final String ticker;
  final AssetType assetType;

  @override
  bool operator ==(Object other) =>
      other is SelectedAsset &&
      other.ticker == ticker &&
      other.assetType == assetType;

  @override
  int get hashCode => Object.hash(ticker, assetType);
}

/// Selección para el panel de detalle. Existe solo en escritorio: en mobile el detalle es una
/// pantalla aparte (`/asset/:ticker`) y la "selección" es el propio stack de navegación.
///
/// Es un `StateProvider` global y no estado local de la pantalla a propósito: el Dashboard y la
/// Watchlist comparten el mismo panel derecho, así que tocar un tile del heatmap y tocar una
/// fila de la watchlist tienen que apuntar al mismo lugar.
final selectedAssetProvider = StateProvider<SelectedAsset?>((ref) => null);
