import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../data/ohlc_data.dart';

/// Ventana por defecto del chart. 30 días de velas diarias entran legibles en el ancho del panel
/// de detalle sin que las velas queden como líneas.
const int kDefaultHistoryDays = 30;

/// Histórico OHLC de un ticker, family por símbolo: abrir NVDA y después AAPL son dos consultas
/// distintas y cacheadas por separado.
///
/// `autoDispose` para que cerrar la ficha libere el histórico en vez de acumular un mes de velas
/// por cada activo que el usuario haya mirado en la sesión.
final tickerHistoryProvider =
    FutureProvider.autoDispose.family<TickerHistory, String>(
  (ref, ticker) => ref
      .watch(historyRepositoryProvider)
      .getHistory(ticker, days: kDefaultHistoryDays),
);
