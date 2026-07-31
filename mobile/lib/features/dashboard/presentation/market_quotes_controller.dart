import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../data/market_quote.dart';

/// `autoDispose`: se refresca cada vez que se vuelve a entrar al Dashboard, igual que
/// `watchlistProvider` (`features/watchlist/presentation/watchlist_controller.dart`).
final marketQuotesProvider = FutureProvider.autoDispose<List<TickerQuote>>(
  (ref) => ref.watch(marketDataRepositoryProvider).getWatchlistQuotes(),
);
