import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../data/watchlist_models.dart';

/// `autoDispose`: se libera cuando ninguna pantalla lo está mirando, así el Dashboard y la
/// Watchlist siempre ven una lista fresca al volver a entrar en vez de un caché viejo.
/// Después de un `add`/`remove`, quien llame debe `ref.invalidate(watchlistProvider)` para
/// refrescar — ver `watchlist_screen.dart`.
final watchlistProvider = FutureProvider.autoDispose<List<WatchlistItem>>(
  (ref) => ref.watch(watchlistRepositoryProvider).list(),
);
