/// Bolsa preferida del usuario. Se persiste local (`PreferencesStorage`) y viaja al backend
/// como `?exchange=` en `GET /api/v1/watchlist` y `GET /api/v1/tickers`, que filtran por ella.
///
/// Solo tiene las dos bolsas que el producto ofrece elegir. El backend además maneja `OTHER`
/// (NYSE Arca, NYSE American, Cboe… ver `ExchangeType` en `app/models/enums.py`): al parsear,
/// ese valor cae en `null` vía `exchangeTypeFromWire` — no es un error, es un ticker de una
/// bolsa que todavía no está en el selector.
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
