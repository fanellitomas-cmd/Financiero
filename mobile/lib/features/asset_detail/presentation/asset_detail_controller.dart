import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/ticker_socket_service.dart';
import '../../../core/providers.dart';
import '../../watchlist/data/watchlist_models.dart';
import '../data/push_notification_payload.dart';

/// Una conexión WebSocket nueva por ticker (no un singleton compartido): a diferencia del
/// `ApiClient` (un cliente HTTP que sí conviene reutilizar entre requests), acá cada
/// `TickerSocketService` guarda el estado de UNA conexión — reusar la misma instancia entre
/// dos tickers pisaría el socket del anterior. `autoDispose` cierra la conexión al salir de
/// la Ficha (ver `ref.onDispose`).
final tickerPayloadProvider = StreamProvider.autoDispose
    .family<PushNotificationPayload, String>((ref, ticker) {
  final config = ref.watch(appConfigProvider);
  final socketService = TickerSocketService(config);
  ref.onDispose(socketService.disconnect);

  return socketService.connect(ticker).map(PushNotificationPayload.fromJson);
});

/// Fetch on-demand contra `GET /api/v1/assets/{ticker}` (`AssetRepository`) — se dispara una
/// vez al abrir la Ficha, para no depender de esperar la próxima corrida del scheduler. El
/// WebSocket de `tickerPayloadProvider` sigue activo en paralelo: si llega una alerta nueva
/// mientras la pantalla está abierta, la pantalla la prioriza sobre este resultado (ver
/// `asset_detail_screen.dart`).
final assetIntelligenceProvider = FutureProvider.autoDispose
    .family<PushNotificationPayload, (String, AssetType)>((ref, args) {
  final (ticker, assetType) = args;
  return ref.watch(assetRepositoryProvider).getAssetIntelligence(ticker, assetType);
});
