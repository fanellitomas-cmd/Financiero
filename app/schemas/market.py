"""Schemas de los endpoints de `/api/v1/market`: `quotes` (Heatmap del Dashboard), `summary`
(Resumen Diario del Mercado) y `history/{ticker}` (velas OHLC para el chart de la Ficha).
"""

from __future__ import annotations

from datetime import date, datetime

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import ExchangeType
from src.validation.domain_models import DataStatus


class TickerQuote(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ticker: str
    last_price: float | None
    day_change_pct: float | None
    status: DataStatus


class MarketMoverOut(BaseModel):
    """Un ticker entre las mayores alzas o bajas de la jornada, ya enriquecido con la bolsa.

    `exchange` es opcional porque el endpoint de movers de Polygon no la trae: se resuelve
    cruzando contra el catálogo local, y un símbolo que todavía no está sincronizado queda en
    `null` en vez de asumirle una bolsa (mismo criterio que `WatchlistItem.exchange`).
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ticker: str
    name: str | None = None
    exchange: ExchangeType | None = None
    last_price: float | None = None
    day_change_pct: float | None = None


class MarketSentiment(BaseModel):
    """El juicio del modelo sobre el tono de la jornada. Separado del texto para que el cliente
    pueda pintarlo (verde/ámbar/rojo) sin parsear prosa.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    label: str = Field(description="ALCISTA | NEUTRAL | BAJISTA")
    confidence_pct: float | None = None


class MarketSummary(BaseModel):
    """Respuesta de `GET /api/v1/market/summary`.

    Los datos duros (`top_gainers`/`top_losers`) y la narrativa del modelo (`headline`,
    `key_points`, `sentiment`) están separados a propósito: si Gemini no está configurado o
    falla, los movers siguen sirviéndose y solo la parte narrativa queda vacía, con
    `ai_narrative_available=False` diciéndolo explícitamente. El cliente nunca tiene que
    adivinar si un resumen vacío es "mercado tranquilo" o "el modelo no respondió".
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    generated_at: datetime
    exchanges: list[ExchangeType]

    top_gainers: list[MarketMoverOut]
    top_losers: list[MarketMoverOut]

    headline: str | None = None
    key_points: list[str] = Field(default_factory=list)
    sentiment: MarketSentiment | None = None

    ai_narrative_available: bool = False
    market_data_available: bool = False
    served_from_cache: bool = False
    degradation_reason: str | None = None


class OhlcBarOut(BaseModel):
    """Una vela del histórico, en el formato compacto que espera un chart: `{t, o, h, l, c, v}`.

    Nombres de un solo carácter a propósito — es la convención de las librerías de charting
    (Lightweight Charts, fl_chart, TradingView) y en un payload de 30+ velas la diferencia de
    tamaño se nota. Los nombres largos viven en el modelo de ingesta
    (`src/ingestion/schemas_raw.py::OhlcBar`), que es donde importa la legibilidad.

    `t` en milisegundos, tal como lo devuelve Polygon. `o`/`h`/`l`/`c`/`v` van como `float` y no
    `Decimal` porque son coordenadas de un gráfico, no montos sobre los que se calcule: acá la
    precisión exacta no aporta y el JSON queda más chico.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    t: int
    o: float
    h: float
    l: float
    c: float
    v: float


class TickerHistory(BaseModel):
    """Respuesta de `GET /api/v1/market/history/{ticker}`.

    `bars` vacío es una respuesta válida con 200, no un error: el proveedor puede estar caído, sin
    configurar, o el rango puede no tener datos (fin de semana, ticker delistado). El cliente
    dibuja "sin histórico" y el resto de la Ficha sigue funcionando. `degradation_reason` dice cuál
    de esos casos fue, para no dejar al usuario adivinando.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ticker: str
    start: date
    end: date
    bars: list[OhlcBarOut] = Field(default_factory=list)
    degradation_reason: str | None = None
