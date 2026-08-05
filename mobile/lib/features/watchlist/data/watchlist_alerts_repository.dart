import '../../../core/network/api_client.dart';
import 'watchlist_alert_rule.dart';

/// Envuelve `/api/v1/watchlist/alerts` (`app/api/v1/watchlist_alerts.py`) — el ABM de reglas de
/// alerta contextuales.
///
/// No confundir con `AlertsRepository` (`features/alerts/`), que lee el Centro de Notificaciones
/// (`GET /api/v1/alerts`): aquello es el historial de lo que ya pasó, esto es la configuración de
/// qué querés que te avisen.
///
/// El cuerpo de create/update lo arma `WatchlistAlertRuleDraft`, no este repositorio: es el que
/// sabe qué campos corresponden a cada tipo, y el backend rechaza con 422 los de otro tipo.
class WatchlistAlertsRepository {
  WatchlistAlertsRepository(this._apiClient);

  final ApiClient _apiClient;

  /// Reglas de TODOS los tickers del usuario, o las de uno solo con `ticker`.
  ///
  /// Un ticker que no aparece en la respuesta no está "sin alertas": significa que recibe TODAS
  /// las que el motor produzca sobre él, que es el comportamiento por defecto. La UI lo dice
  /// explícito en vez de mostrar un vacío que se leería como silencio.
  Future<List<WatchlistAlertRule>> list({
    String? ticker,
    AlertRuleType? alertType,
  }) async {
    final response = await _apiClient.dio.get(
      '/watchlist/alerts',
      queryParameters: {
        if (ticker != null) 'ticker': ticker,
        if (alertType != null) 'alert_type': alertType.wireValue,
      },
    );
    return (response.data as List)
        .map(
          (rule) => WatchlistAlertRule.fromJson(rule as Map<String, dynamic>),
        )
        .toList();
  }

  Future<WatchlistAlertRule> create(
    String ticker,
    WatchlistAlertRuleDraft draft,
  ) async {
    final response = await _apiClient.dio.post(
      '/watchlist/alerts',
      data: draft.toCreateJson(ticker),
    );
    return WatchlistAlertRule.fromJson(response.data as Map<String, dynamic>);
  }

  Future<WatchlistAlertRule> update(
    String ruleId,
    WatchlistAlertRuleDraft draft,
  ) async {
    final response = await _apiClient.dio.patch(
      '/watchlist/alerts/$ruleId',
      data: draft.toUpdateJson(),
    );
    return WatchlistAlertRule.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> remove(String ruleId) =>
      _apiClient.dio.delete('/watchlist/alerts/$ruleId');
}
