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
