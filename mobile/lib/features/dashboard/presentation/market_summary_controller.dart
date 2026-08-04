import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../data/market_summary.dart';

/// El resumen del día. `autoDispose` como el resto de los providers de pantalla, para que volver
/// al Dashboard traiga el estado actual y no uno de hace una hora.
///
/// Refrescarlo es barato: el backend lo tiene cacheado en memoria y solo recalcula (y consulta al
/// modelo) cuando vence el TTL. Por eso el pull-to-refresh puede invalidarlo sin más.
final marketSummaryProvider = FutureProvider.autoDispose<MarketSummary>(
  (ref) => ref.watch(marketSummaryRepositoryProvider).getSummary(),
);
