import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../network/api_client.dart';

/// Registra el token FCM del dispositivo contra `POST /api/v1/devices`
/// (`app/api/v1/devices.py`) para que el backend pueda despachar push personalizado a este
/// dispositivo además del broadcast por tópico/WebSocket. Llamar una vez después de un login
/// exitoso; `onTokenRefresh` reintenta el registro solo si Firebase rota el token.
class PushService {
  PushService(this._apiClient);

  final ApiClient _apiClient;

  Future<void> requestPermissionAndRegister() async {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);

    final token = await messaging.getToken();
    if (token != null) {
      await _registerToken(token);
    }

    messaging.onTokenRefresh.listen(_registerToken);
  }

  Future<void> _registerToken(String token) async {
    await _apiClient.dio.post(
      '/devices',
      data: {'fcm_token': token, 'platform': _currentPlatform()},
    );
  }

  /// `defaultTargetPlatform` (no `dart:io Platform`) porque este archivo también se compila
  /// para Web, donde `dart:io` ni siquiera está disponible.
  String _currentPlatform() {
    if (kIsWeb) return 'WEB';
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'IOS',
      TargetPlatform.android => 'ANDROID',
      _ => 'ANDROID',
    };
  }
}
