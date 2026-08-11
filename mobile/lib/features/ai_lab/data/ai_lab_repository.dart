import '../../../core/network/api_client.dart';
import 'ai_lab_models.dart';

/// Envuelve `/api/v1/ai-lab/*` (`app/api/v1/ai_lab.py`) — el diagnóstico contable y el simulador.
///
/// Los dos endpoints son `POST` aunque no escriban nada: el diagnóstico manda un historial de
/// conversación que no cabe razonablemente en un query string, y el simulador manda un objeto de
/// variables anidado que en query params quedaría como parámetros planos imposibles de validar como
/// unidad.
///
/// **Ningún método lanza por falta de datos.** Los dos endpoints responden 200 con su estructura
/// válida, `availability` y un motivo legible incluso sin credenciales, así que acá solo se parsea.
/// Lo único que llega como excepción es un problema de transporte o de sesión.
class AiLabRepository {
  AiLabRepository(this._apiClient);

  final ApiClient _apiClient;

  /// Diagnóstico contable, con o sin pregunta.
  ///
  /// El `history` se manda TAL COMO lo devolvió el backend en el turno anterior: el hilo es del
  /// cliente y el servidor no lo persiste, así que reconstruirlo por nuestra cuenta arriesgaría
  /// mandar un historial que no coincide con lo que el backend efectivamente vio.
  Future<FinancialAnalysisResponse> analyze({
    required String ticker,
    StatementPeriod period = StatementPeriod.annual,
    String? question,
    List<ConversationTurn> history = const [],
  }) async {
    final response = await _apiClient.dio.post(
      '/ai-lab/financial-analysis',
      data: {
        'ticker': ticker,
        'period': statementPeriodToWire(period),
        if (question != null && question.trim().isNotEmpty)
          'question': question.trim(),
        if (history.isNotEmpty)
          'history': history.map((turn) => turn.toJson()).toList(),
      },
    );
    return FinancialAnalysisResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// Simulación "qué pasaría si".
  ///
  /// Las variables se serializan omitiendo las que están sin fijar (ver `ScenarioVariables.toJson`):
  /// mandar un `null` explícito sería fijarlas en null, que el schema rechaza con un 422.
  Future<ScenarioSimulationResult> simulate({
    required String ticker,
    StatementPeriod period = StatementPeriod.annual,
    ScenarioVariables variables = const ScenarioVariables(),
  }) async {
    final response = await _apiClient.dio.post(
      '/ai-lab/simulate',
      data: {
        'ticker': ticker,
        'period': statementPeriodToWire(period),
        'variables': variables.toJson(),
      },
    );
    return ScenarioSimulationResult.fromJson(
      response.data as Map<String, dynamic>,
    );
  }
}
