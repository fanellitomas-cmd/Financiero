import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/ai/data/financial_translator_repository.dart';
import '../features/alerts/data/alerts_repository.dart';
import '../features/asset_detail/data/asset_repository.dart';
import '../features/asset_detail/data/deep_research_repository.dart';
import '../features/asset_detail/data/history_repository.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/auth/presentation/auth_controller.dart';
import '../features/chat/data/chat_repository.dart';
import '../features/dashboard/data/market_data_repository.dart';
import '../features/dashboard/data/market_summary_repository.dart';
import '../features/lab/data/attachments_repository.dart';
import '../features/lab/data/folders_repository.dart';
import '../features/lab/data/notes_repository.dart';
import '../features/settings/data/exchange_type.dart';
import '../features/settings/presentation/exchange_controller.dart';
import '../features/tickers/data/search_nl_repository.dart';
import '../features/tickers/data/ticker_repository.dart';
import '../features/watchlist/data/watchlist_alerts_repository.dart';
import '../features/watchlist/data/watchlist_audit_repository.dart';
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

final watchlistAuditRepositoryProvider = Provider<WatchlistAuditRepository>(
  (ref) => WatchlistAuditRepository(ref.watch(apiClientProvider)),
);

/// Reglas de alerta de la Watchlist (`/watchlist/alerts`) — la configuración de qué avisar. No
/// confundir con `alertsRepositoryProvider`, que lee el historial de lo ya avisado (`/alerts`).
final watchlistAlertsRepositoryProvider = Provider<WatchlistAlertsRepository>(
  (ref) => WatchlistAlertsRepository(ref.watch(apiClientProvider)),
);

final chatRepositoryProvider = Provider<ChatRepository>(
  (ref) => ChatRepository(ref.watch(apiClientProvider)),
);

final assetRepositoryProvider = Provider<AssetRepository>(
  (ref) => AssetRepository(ref.watch(apiClientProvider)),
);

final historyRepositoryProvider = Provider<HistoryRepository>(
  (ref) => HistoryRepository(ref.watch(apiClientProvider)),
);

final deepResearchRepositoryProvider = Provider<DeepResearchRepository>(
  (ref) => DeepResearchRepository(ref.watch(apiClientProvider)),
);

final alertsRepositoryProvider = Provider<AlertsRepository>(
  (ref) => AlertsRepository(ref.watch(apiClientProvider)),
);

final marketDataRepositoryProvider = Provider<MarketDataRepository>(
  (ref) => MarketDataRepository(ref.watch(apiClientProvider)),
);

final marketSummaryRepositoryProvider = Provider<MarketSummaryRepository>(
  (ref) => MarketSummaryRepository(ref.watch(apiClientProvider)),
);

final tickerRepositoryProvider = Provider<TickerRepository>(
  (ref) => TickerRepository(ref.watch(apiClientProvider)),
);

/// Búsqueda conversacional (`POST /tickers/search-nl`). Separada de `tickerRepositoryProvider`
/// porque son dos búsquedas con costos muy distintos: aquella es una query al catálogo local, esta
/// gasta una llamada al modelo más una al proveedor de fundamentales por símbolo.
final searchNlRepositoryProvider = Provider<SearchNlRepository>(
  (ref) => SearchNlRepository(ref.watch(apiClientProvider)),
);

final financialTranslatorRepositoryProvider =
    Provider<FinancialTranslatorRepository>(
  (ref) => FinancialTranslatorRepository(ref.watch(apiClientProvider)),
);

/// Investment Lab: el árbol de carpetas y las notas de investigación.
///
/// Dos repositorios y no uno porque son dos recursos con ciclos de vida distintos: el árbol se lee
/// una vez y cambia poco, las notas se filtran y reescriben todo el tiempo. Un repositorio único
/// obligaría a invalidar los dos juntos en cada mutación.
final foldersRepositoryProvider = Provider<FoldersRepository>(
  (ref) => FoldersRepository(ref.watch(apiClientProvider)),
);

final notesRepositoryProvider = Provider<NotesRepository>(
  (ref) => NotesRepository(ref.watch(apiClientProvider)),
);

/// Capturas de gráficos adjuntas a las notas. Repositorio propio y no un método más de
/// `NotesRepository` porque lo que maneja es distinto: acá se transfieren imágenes, con su propio
/// endpoint de bytes y su propia caché.
final attachmentsRepositoryProvider = Provider<AttachmentsRepository>(
  (ref) => AttachmentsRepository(ref.watch(apiClientProvider)),
);
