import '../../../core/network/api_client.dart';

class ChatMessage {
  const ChatMessage({required this.text, required this.isFromUser});

  final String text;
  final bool isFromUser;
}

/// TODO(backend): el FastAPI actual (`app/api/v1/`) todavía no expone un endpoint
/// conversacional — solo `/watchlist`, `/auth`, `/devices` y `/internal/trigger-agent`. Este
/// repositorio queda con la forma que va a tener el cliente (`send`) para no bloquear el
/// armado de la pantalla de Chat; cuando se agregue, por ejemplo, `POST /api/v1/chat`, la
/// única pieza a cambiar es el cuerpo de este método.
class ChatRepository {
  ChatRepository(this._apiClient);

  // ignore: unused_field
  final ApiClient _apiClient;

  Future<ChatMessage> send(String prompt) async {
    throw UnimplementedError(
      'Falta el endpoint conversacional del backend (ver TODO en chat_repository.dart).',
    );
  }
}
