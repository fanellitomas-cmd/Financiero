"""Schemas Pydantic v2 de `GET /api/v1/tickers` (catálogo de acciones)."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict

from app.models.enums import ExchangeType


class TickerRead(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", from_attributes=True)

    symbol: str
    name: str
    # Se expone el MIC crudo además de la bolsa normalizada: si el cliente ve `OTHER` puede
    # entender por qué (qué bolsa real es) sin tener que consultar el backend.
    primary_exchange: str | None
    exchange: ExchangeType
    asset_type: str | None
    active: bool
    updated_at: datetime


class TickerPage(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    items: list[TickerRead]
    total: int
    limit: int
    offset: int
