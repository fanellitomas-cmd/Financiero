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
