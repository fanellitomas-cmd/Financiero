"""Enums propios de la capa de Producto/Plataforma. `urgency_level` de `AlertHistory` reutiliza
`src.validation.domain_models.AlertSeverity` directamente (ya tiene exactamente LOW/MEDIUM/
HIGH/CRITICAL) en vez de duplicarlo aquí.
"""

from __future__ import annotations

from enum import Enum


class PlanType(str, Enum):
    FREE = "FREE"
    PREMIUM = "PREMIUM"


class AssetType(str, Enum):
    """Vocabulario de cara al usuario/producto (STOCK/CRYPTO). Distinto del `AssetClass`
    interno del motor (`EQUITY`/`CRYPTO`, ver `src/validation/domain_models.py`) a propósito:
    `app/` habla el lenguaje del producto, `src/` el del motor — se traduce explícitamente en
    `app/services/agent_runner_service.py`, nunca se unifican para evitar acoplar ambas capas.
    """

    STOCK = "STOCK"
    CRYPTO = "CRYPTO"


class DevicePlatform(str, Enum):
    IOS = "IOS"
    ANDROID = "ANDROID"
    WEB = "WEB"


class AlertRuleType(str, Enum):
    """Tipo de regla de alerta configurada por el usuario sobre un item de su Watchlist.

    `PRICE` es la regla clásica (variación porcentual). Las otras dos son contextuales: no miran
    el precio sino la INTERPRETACIÓN que el motor produjo sobre el activo — la severidad de la
    noticia y la dirección proyectada por horizonte. Esa distinción es el punto: un umbral de
    precio no distingue una caída del 5% por nerviosismo de una del 5% por deterioro real, y esa
    diferencia es justamente lo que el motor calcula.
    """

    PRICE = "PRICE"
    NEWS_SEVERITY = "NEWS_SEVERITY"
    TREND_BREAK = "TREND_BREAK"


class TrendHorizon(str, Enum):
    """Horizonte de una regla `TREND_BREAK`, en el vocabulario del producto.

    Se mapea a los `horizon` del motor (`CORTO_1_14D` / `MEDIANO_1_6M` / `LARGO_1_3A`, ver
    `src/validation/domain_models.py::HorizonScenarios`) en
    `app/services/watchlist_alert_service.py`. Se declara aparte y no se reutiliza el Literal del
    motor para que el contrato de la API no cambie si el motor renombra sus horizontes.
    """

    CORTO = "CORTO"
    MEDIANO = "MEDIANO"
    LARGO = "LARGO"


class TrendBreakDirection(str, Enum):
    """Qué quiebre de tendencia le interesa al usuario.

    `BAJISTA` es el default del producto (avisar cuando la proyección se da vuelta en contra),
    pero `ALCISTA` es un caso real: alguien esperando un punto de entrada quiere saber cuándo la
    tendencia se da vuelta a favor. `CUALQUIERA` cubre ambos.
    """

    BAJISTA = "BAJISTA"
    ALCISTA = "ALCISTA"
    CUALQUIERA = "CUALQUIERA"


class ExchangeType(str, Enum):
    """Bolsa normalizada, en el vocabulario del producto — es lo que filtra
    `GET /api/v1/tickers?exchange=...` y lo que elige el usuario en la app (ver
    `mobile/lib/features/settings/data/exchange_type.dart`).

    Distinto del `primary_exchange` crudo que devuelve Polygon, que es un código MIC
    (ISO 10383: `XNAS`, `XNYS`, `ARCX`…). La traducción MIC -> `ExchangeType` vive en
    `app/services/ticker_catalog_service.py`, y `Ticker` guarda LAS DOS cosas: el MIC crudo
    del proveedor y esta forma normalizada.

    `OTHER` cubre las bolsas que existen pero que el producto todavía no ofrece como opción
    (NYSE American, NYSE Arca, Cboe…): esos tickers se ingestan igual, marcados como OTHER, en
    vez de descartarse en silencio.
    """

    NASDAQ = "NASDAQ"
    NYSE = "NYSE"
    OTHER = "OTHER"
