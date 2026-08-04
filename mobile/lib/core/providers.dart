import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/alerts/data/alerts_repository.dart';
import '../features/asset_detail/data/asset_repository.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/auth/presentation/auth_controller.dart';
import '../features/chat/data/chat_repository.dart';
import '../features/dashboard/data/market_data_repository.dart';
import '../features/settings/data/exchange_type.dart';
import '../features/settings/presentation/exchange_controller.dart';
import '../features/tickers/data/ticker_repository.dart';
import '../features/watchlist/data/watchlist_repository.dart';
import 'config/app_config.dart';
import 'network/api_client.dart';
import 'push/push_service.dart';
import 'storage/preferences_storage.dart';
import 'storage/token_storage.dart';

/// Todos los providers de infraestructura viven acá: cada uno se construye una sola vez por
/// sesión de la app (mismo principio de "un cliente reutilizado, nunca uno por request/pantalla"
/// que ya sigue el backend con Dio/WebSocket/FCM), y las pantallas los consumen por
/// `ref.watch`/`ref.read` sin instanciar nada por su cuenta.

final appConfigProvider = Provider<AppConfig>((ref) => AppConfig.defaultConfig);

final tokenStorageProvider = Provider<TokenStorage>((ref) => TokenStorage());

final preferencesStorageProvider = Provider<PreferencesStorage>(
  (ref) => PreferencesStorage(),
);

final exchangeControllerProvider =
    StateNotifierProvider<ExchangeController, ExchangePreferenceState>(
  (ref) => ExchangeController(ref.watch(preferencesStorageProvider)),
);

/// Atajo de solo-lectura para las pantallas que únicamente necesitan saber qué bolsa está
/// elegida (sin el estado de carga ni los métodos del controller) — `null` mientras no haya
/// una selección. Para cambiarla, usar `exchangeControllerProvider.notifier.select(...)`.
final selectedExchangeProvider = Provider<ExchangeType?>(
  (ref) => ref.watch(exchangeControllerProvider).selected,
);

// Tipo explícito en la variable (no solo en el genérico del constructor): sin esto, el
// analyzer detecta un ciclo de inferencia de tipos entre apiClientProvider ->
// authControllerProvider -> authRepositoryProvider -> apiClientProvider (el ciclo es real a
// nivel de referencias en las clausuras, aunque en runtime nunca se ejecuta circularmente —
// `onUnauthorized` recién llama a `authControllerProvider` ante un 401, mucho después de que
// todos los providers ya se construyeron).
final Provider<ApiClient> apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(
    config: ref.watch(appConfigProvider),
    tokenStorage: ref.watch(tokenStorageProvider),
    // Un 401 de cualquier request desloguea la sesión; el router (app_router.dart) reacciona
    // solo, vía `refreshListenable`, redirigiendo a /login — no hace falta navegar desde acá.
    onUnauthorized: () => ref.read(authControllerProvider.notifier).logout(),
  );
});

final pushServiceProvider = Provider<PushService>(
  (ref) => PushService(ref.watch(apiClientProvider)),
);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(
      ref.watch(apiClientProvider), ref.watch(tokenStorageProvider)),
);

final authControllerProvider = StateNotifierProvider<AuthController, AuthState>(
  (ref) => AuthController(ref.watch(authRepositoryProvider)),
);

final watchlistRepositoryProvider = Provider<WatchlistRepository>(
  (ref) => WatchlistRepository(ref.watch(apiClientProvider)),
);

final chatRepositoryProvider = Provider<ChatRepository>(
  (ref) => ChatRepository(ref.watch(apiClientProvider)),
);

final assetRepositoryProvider = Provider<AssetRepository>(
  (ref) => AssetRepository(ref.watch(apiClientProvider)),
);

final alertsRepositoryProvider = Provider<AlertsRepository>(
  (ref) => AlertsRepository(ref.watch(apiClientProvider)),
);

final marketDataRepositoryProvider = Provider<MarketDataRepository>(
  (ref) => MarketDataRepository(ref.watch(apiClientProvider)),
);

final tickerRepositoryProvider = Provider<TickerRepository>(
  (ref) => TickerRepository(ref.watch(apiClientProvider)),
);
