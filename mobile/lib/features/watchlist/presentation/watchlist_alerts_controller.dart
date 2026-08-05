import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../data/watchlist_alert_rule.dart';

/// Todas las reglas de alerta del usuario, de todos sus tickers.
///
/// Una sola consulta para toda la watchlist en vez de una por fila: la pantalla necesita saber
/// qué items tienen reglas para mostrarles el indicador, y N requests para N filas sería un
/// request por ticker cada vez que se abre la lista.
///
/// `autoDispose`: al volver a la pantalla se relee, así una regla configurada desde otro
/// dispositivo aparece sin necesidad de reiniciar la app.
final watchlistAlertRulesProvider =
    FutureProvider.autoDispose<List<WatchlistAlertRule>>(
  (ref) => ref.watch(watchlistAlertsRepositoryProvider).list(),
);

/// Las reglas de un ticker, derivadas de la lista completa.
///
/// Deriva del provider de arriba en vez de pegarle al endpoint con `?ticker=`: el diálogo se abre
/// sobre datos que la pantalla ya tiene, así que abrirlo no dispara un request ni muestra un
/// spinner por algo que está en memoria.
final tickerAlertRulesProvider =
    Provider.autoDispose.family<List<WatchlistAlertRule>, String>(
  (ref, ticker) {
    final rules = ref.watch(watchlistAlertRulesProvider).valueOrNull ?? [];
    return rules.where((rule) => rule.ticker == ticker).toList();
  },
);
