import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/app_config.dart';

/// Conexión WebSocket a `WS /api/v1/ws/{ticker}` (`app/api/v1/websocket.py` del backend):
/// recibe en vivo el `PushNotificationPayload` que arma el Nodo 5 cuando el motor despacha una
/// alerta para ese ticker (broadcast vía `TickerConnectionManager`, ver
/// `app/services/push_service.py`).
///
/// Una instancia por ticker suscripto — no comparte conexión entre tickers, así la Ficha de un
/// activo puede abrirse/cerrarse independientemente del resto de la app.
class TickerSocketService {
  TickerSocketService(this._config);

  final AppConfig _config;
  WebSocketChannel? _channel;

  Stream<Map<String, dynamic>> connect(String ticker) {
    final uri = Uri.parse('${_config.wsBaseUrl}/ws/${ticker.toUpperCase()}');
    final channel = WebSocketChannel.connect(uri);
    _channel = channel;
    return channel.stream.map(
      (event) => jsonDecode(event as String) as Map<String, dynamic>,
    );
  }

  Future<void> disconnect() async {
    await _channel?.sink.close();
    _channel = null;
  }
}
