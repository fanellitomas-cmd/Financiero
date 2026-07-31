import '../../asset_detail/data/push_notification_payload.dart';

/// Espeja `AlertHistoryRead`/`AlertHistoryPage` (`app/schemas/alert.py`). `payloadJson` queda
/// como mapa crudo (no se re-parsea a `PushNotificationPayload`): el Centro de Notificaciones
/// solo necesita mostrar un resumen de la lista, no reabrir la Ficha completa desde acá.
class AlertHistoryItem {
  const AlertHistoryItem({
    required this.id,
    required this.ticker,
    required this.payloadJson,
    required this.urgencyLevel,
    required this.createdAt,
  });

  factory AlertHistoryItem.fromJson(Map<String, dynamic> json) => AlertHistoryItem(
        id: json['id'] as String,
        ticker: json['ticker'] as String,
        payloadJson: json['payload_json'] as Map<String, dynamic>,
        urgencyLevel: alertUrgencyFromJson(json['urgency_level'] as String),
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  final String id;
  final String ticker;
  final Map<String, dynamic> payloadJson;
  final AlertUrgency urgencyLevel;
  final DateTime createdAt;

  String? get shortSummary => payloadJson['short_summary'] as String?;
  String? get title => payloadJson['title'] as String?;
}

class AlertHistoryPage {
  const AlertHistoryPage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  factory AlertHistoryPage.fromJson(Map<String, dynamic> json) => AlertHistoryPage(
        items: (json['items'] as List)
            .map((item) => AlertHistoryItem.fromJson(item as Map<String, dynamic>))
            .toList(),
        total: json['total'] as int,
        limit: json['limit'] as int,
        offset: json['offset'] as int,
      );

  final List<AlertHistoryItem> items;
  final int total;
  final int limit;
  final int offset;
}
