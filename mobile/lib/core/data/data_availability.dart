/// Estado de disponibilidad de un bloque de datos que el backend compone de varias fuentes.
///
/// Vive en `core/` y no en una feature porque ya lo usan dos contratos distintos —la Ficha de
/// Inteligencia Profunda (`/tickers/{ticker}/intelligence`) y la Auditoría de Portafolio
/// (`/watchlist/audit`)— y del lado del backend es literalmente el mismo enum
/// (`app/schemas/intelligence.py::DataAvailability`). Tener dos copias con los mismos tres valores
/// obligaría a mapear entre ellas sin ninguna ganancia.
library;

/// `partial` es un estado real y frecuente, no un caso raro: un ticker con P/E pero sin PEG, o una
/// auditoría con sectores resueltos pero sin narrativa. Es distinto tanto de "todo bien" como de
/// "no hay nada", y la UI lo pinta distinto.
enum DataAvailability { available, partial, unavailable }

/// `unavailable` ante un valor desconocido: es el fallback seguro — la UI muestra el banner
/// informativo en vez de presentar un bloque vacío como si tuviera datos.
DataAvailability availabilityFromWire(String? value) => switch (value) {
      'AVAILABLE' => DataAvailability.available,
      'PARTIAL' => DataAvailability.partial,
      'UNAVAILABLE' => DataAvailability.unavailable,
      _ => DataAvailability.unavailable,
    };
