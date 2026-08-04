"""Schemas Pydantic v2 de request/response para `Watchlists`."""

from __future__ import annotations

from decimal import Decimal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import AssetType, ExchangeType


class WatchlistItemCreate(BaseModel):
    # strict=False (default) deliberado acá, a diferencia del resto del proyecto: este schema
    # valida JSON externo de un request HTTP, y JSON no tiene tipo nativo para Decimal/Enum —
    # llegan como string/number y necesitan coerción (mismo caso que la salida de Gemini en
    # src/processing/scenario_evaluator.py). Los modelos de dominio internos siguen strict.
    model_config = ConfigDict(extra="forbid")

    ticker: str = Field(min_length=1, max_length=20)
    asset_type: AssetType
    alert_threshold_pct: Decimal = Field(default=Decimal("3.0"), gt=0, le=100)
    enable_beginner_mode: bool = False


class WatchlistItemUpdate(BaseModel):
    # strict=False deliberado, mismo motivo que WatchlistItemCreate arriba: valida JSON
    # externo de un request HTTP. Todos los campos son opcionales — PATCH parcial, no PUT.
    model_config = ConfigDict(extra="forbid")

    alert_threshold_pct: Decimal | None = Field(default=None, gt=0, le=100)
    enable_beginner_mode: bool | None = None


class WatchlistItemRead(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", from_attributes=True)

    id: UUID
    ticker: str
    asset_type: AssetType
    alert_threshold_pct: Decimal
    enable_beginner_mode: bool
    # Resuelto por el backend desde el catálogo `tickers`, no enviado por el cliente. `None`
    # cuando el símbolo no está en el catálogo (cripto, o una acción todavía no sincronizada).
    exchange: ExchangeType | None
