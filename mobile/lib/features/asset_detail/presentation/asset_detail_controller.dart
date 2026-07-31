import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/ticker_socket_service.dart';
import '../../../core/providers.dart';
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
