import '../../../core/network/api_client.dart';
import 'financial_translation.dart';

/// Envuelve `POST /api/v1/ai/translate-financial` (`app/api/v1/ai.py`) — el Traductor Financiero.
///
/// El endpoint siempre responde 200 con estructura válida: un entorno sin credenciales de IA
/// devuelve `available=false` con su motivo, no un 503. El toggle "Explicar para Principiantes" es
/// una ayuda opcional, así que el estado no disponible se muestra como aviso en línea y no como un
/// error de la pantalla que lo contiene.
///
/// El backend cachea por CONTENIDO (texto + contexto) durante 24 horas, no por usuario: pedir dos
/// veces la misma explicación es gratis, y el mismo término en la Ficha de dos usuarios distintos
/// gasta una sola llamada al modelo. Por eso el cliente no necesita caché propia más allá de la de
/// Riverpod.
class FinancialTranslatorRepository {
  FinancialTranslatorRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<FinancialTranslation> translate(
    String text, {
    String? context,
  }) async {
    final response = await _apiClient.dio.post(
      '/ai/translate-financial',
      data: {
        'text': text,
        if (context != null && context.isNotEmpty) 'context': context,
      },
    );
    return FinancialTranslation.fromJson(response.data as Map<String, dynamic>);
  }
}
