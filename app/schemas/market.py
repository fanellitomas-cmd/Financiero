"""Schema de `GET /api/v1/market/quotes` (Heatmap del Dashboard)."""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict

from src.validation.domain_models import DataStatus


class TickerQuote(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ticker: str
    last_price: float | None
    day_change_pct: float | None
    status: DataStatus
