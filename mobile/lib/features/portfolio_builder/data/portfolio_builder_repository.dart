import '../../../core/network/api_client.dart';
import 'portfolio_builder_models.dart';

/// Envuelve `POST /api/v1/portfolio-builder/simulate` (`app/api/v1/portfolio_builder.py`).
///
/// Es `POST` aunque no escriba nada: el cuerpo lleva una lista de objetos anidados con tipo de
/// asignación y precio esperado por posición, que en query params quedaría como listas paralelas
/// imposibles de validar como unidad.
///
/// **No lanza por falta de datos.** El endpoint responde 200 con su estructura válida,
/// `availability` y un motivo legible incluso sin credenciales de mercado, así que acá solo se
/// parsea. Lo único que llega como excepción es un problema de transporte, de sesión, o un 422 —
/// que sería un bug del cliente, no un estado del dominio.
class PortfolioBuilderRepository {
  PortfolioBuilderRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<PortfolioSimulationResult> simulate(
    PortfolioSimulationRequest request,
  ) async {
    final response = await _apiClient.dio.post(
      '/portfolio-builder/simulate',
      data: request.toJson(),
    );
    return PortfolioSimulationResult.fromJson(
      response.data as Map<String, dynamic>,
    );
  }
}
