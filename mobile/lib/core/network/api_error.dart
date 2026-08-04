import 'package:dio/dio.dart';

/// Traduce un error de red/API a un mensaje legible para la UI — nunca se muestra un
/// `Exception: ...` crudo ni un stack trace. Prioriza el `detail` que ya manda el backend
/// (FastAPI `HTTPException(detail=...)`) porque suele ser más específico que un mensaje
/// genérico por código de estado.
String describeApiError(Object error) {
  if (error is DioException) {
    final responseData = error.response?.data;
    final detail = responseData is Map && responseData['detail'] is String
        ? responseData['detail'] as String
        : null;
    if (detail != null) return detail;

    final statusCode = error.response?.statusCode;
    if (statusCode == 503) {
      return 'Este servicio no está configurado en el backend todavía.';
    }
    if (statusCode == 502) {
      return 'El servicio externo falló. Probá de nuevo en un rato.';
    }
    if (statusCode == 404) {
      return 'No se encontró lo que buscabas.';
    }
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.connectionError) {
      return 'No se pudo conectar con el servidor. Revisá tu conexión.';
    }
    return 'Ocurrió un error de red inesperado.';
  }
  return 'Ocurrió un error inesperado.';
}
