"""Schemas Pydantic v2 para `AlertHistory` y el endpoint interno `/internal/trigger-agent`."""

from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import AssetType
from src.validation.domain_models import AlertSeverity


class AlertHistoryRead(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", from_attributes=True)

    id: UUID
    ticker: str
    payload_json: dict[str, Any]
    urgency_level: AlertSeverity
    created_at: datetime


class AlertHistoryPage(BaseModel):
    """Página de `GET /api/v1/alerts` — filtrada a los tickers de la Watchlist del usuario
    autenticado, más nuevo primero.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    items: list[AlertHistoryRead]
    total: int
    limit: int
    offset: int


class TriggerAgentRequest(BaseModel):
    """Cuerpo opcional del disparo del Cron/Scheduler. Si `tickers` es `None`, se corre sobre
    todos los tickers distintos presentes en `Watchlists` — el uso normal para un cron
    periódico. Pasar `tickers` explícito sirve para reintentar/depurar un subconjunto puntual.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    tickers: list[str] | None = Field(default=None, min_length=1)


class TickerRunResult(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    ticker: str
    asset_type: AssetType
    alert_generated: bool
    urgency_level: AlertSeverity | None = None
    push_dispatched: bool = False
    watcher_count: int = 0
    error: str | None = None


class TriggerAgentResponse(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    tickers_processed: int
    alerts_generated: int
    results: list[TickerRunResult]
