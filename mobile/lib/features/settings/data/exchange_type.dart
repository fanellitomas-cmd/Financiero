/// Bolsa preferida del usuario. Por ahora es una preferencia 100% del cliente: el backend
/// no tiene concepto de exchange en su esquema (`app/models/watchlist.py` guarda ticker +
/// asset_type, sin la bolsa donde cotiza), así que no viaja en ningún request todavía. Ver
/// `mobile/README.md` para lo que falta del lado del backend para poder filtrar por bolsa.
enum ExchangeType { nasdaq, nyse }

extension ExchangeTypeX on ExchangeType {
  /// Valor persistido/serializado. Se mantiene estable aunque cambie el nombre del enum:
  /// si esto cambiara, las preferencias ya guardadas dejarían de leerse.
  String get wireValue => switch (this) {
        ExchangeType.nasdaq => 'NASDAQ',
        ExchangeType.nyse => 'NYSE',
      };

  String get displayName => switch (this) {
        ExchangeType.nasdaq => 'NASDAQ',
        ExchangeType.nyse => 'NYSE',
      };

  String get description => switch (this) {
        ExchangeType.nasdaq =>
          'Principalmente tecnología y growth (AAPL, MSFT, NVDA, TSLA).',
        ExchangeType.nyse =>
          'Principalmente industriales, financieras y blue chips (JPM, KO, WMT).',
      };
}

/// Devuelve `null` en vez de lanzar ante un valor desconocido: esto lee de disco, y una
/// preferencia guardada por una versión futura de la app (o un valor corrupto) no debe
/// crashear el arranque — se trata como "sin preferencia" y se vuelve a preguntar.
ExchangeType? exchangeTypeFromWire(String? value) => switch (value) {
      'NASDAQ' => ExchangeType.nasdaq,
      'NYSE' => ExchangeType.nyse,
      _ => null,
    };
