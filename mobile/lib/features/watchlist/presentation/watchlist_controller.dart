import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../data/watchlist_models.dart';

/// Watchlist del usuario, filtrada por la bolsa activa.
///
/// El `ref.watch(selectedExchangeProvider)` es lo que hace el filtrado automático: al cambiar
/// de bolsa en el AppBar, Riverpod invalida este provider y vuelve a pedir la lista al backend
/// con el nuevo `?exchange=` — la pantalla se reactiva sola, sin que el selector tenga que
/// saber que la watchlist existe.
///
/// `autoDispose`: se libera cuando ninguna pantalla lo está mirando, así el Dashboard y la
/// Watchlist siempre ven una lista fresca al volver a entrar en vez de un caché viejo.
/// Después de un `add`/`remove`, quien llame debe `ref.invalidate(watchlistProvider)` para
/// refrescar — ver `watchlist_screen.dart`.
final watchlistProvider =
    FutureProvider.autoDispose<List<WatchlistItem>>((ref) {
  final exchange = ref.watch(selectedExchangeProvider);
  return ref.watch(watchlistRepositoryProvider).list(exchange: exchange);
});

/// La watchlist COMPLETA, sin filtrar por bolsa. La usa el Dashboard para el heatmap y la
/// pantalla de Watchlist para saber si hay items escondidos por el filtro activo — sin esto,
/// una watchlist con solo cripto se vería vacía al elegir NASDAQ y parecería un bug.
final fullWatchlistProvider = FutureProvider.autoDispose<List<WatchlistItem>>(
  (ref) => ref.watch(watchlistRepositoryProvider).list(),
);
