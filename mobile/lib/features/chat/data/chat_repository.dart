import '../../../core/network/api_client.dart';

class ChatMessage {
  const ChatMessage({required this.text, required this.isFromUser});

  final String text;
  final bool isFromUser;
}

/// Respuesta estructurada de `POST /api/v1/chat` (`app/schemas/chat.py::ChatResponse`).
/// `groundedInRecentAlert` indica si la respuesta se apoyó en un `AlertHistory` reciente del
/// ticker mencionado, o si el modelo respondió sin contexto de mercado — la UI lo muestra
/// como una aclaración, nunca lo oculta (mismo espíritu de "declarar explícito" que el resto
/// del proyecto).
class ChatResponse {
  const ChatResponse({
    required this.reply,
    required this.referencedTicker,
    required this.groundedInRecentAlert,
  });

  factory ChatResponse.fromJson(Map<String, dynamic> json) => ChatResponse(
        reply: json['reply'] as String,
        referencedTicker: json['referenced_ticker'] as String?,
        groundedInRecentAlert: json['grounded_in_recent_alert'] as bool,
      );

  final String reply;
  final String? referencedTicker;
  final bool groundedInRecentAlert;
}

/// Envuelve `POST /api/v1/chat` (`app/api/v1/chat.py`). `ticker` es opcional: si se pasa, el
/// backend arma contexto desde el último `AlertHistory` de ese ticker (si existe) antes de
/// preguntarle a Gemini.
class ChatRepository {
  ChatRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<ChatResponse> send(String prompt, {String? ticker}) async {
    final response = await _apiClient.dio.post(
      '/chat',
      data: {'prompt': prompt, if (ticker != null) 'ticker': ticker},
    );
    return ChatResponse.fromJson(response.data as Map<String, dynamic>);
  }
}
