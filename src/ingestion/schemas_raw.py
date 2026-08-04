"""Modelos Pydantic que reflejan la salida ya parseada (pero no interpretada) de cada
proveedor externo (.cursorrules §3: la ingesta parsea y devuelve el modelo crudo, nunca
decide). Reutilizan `MetricValue`/`DataStatus` de `validation/domain_models.py` para marcar
explícitamente ausencia de dato campo por campo, en vez de rellenar con un valor por defecto.
"""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field

from src.validation.domain_models import (
    AssetClass,
    DataStatus,
    EvidenceItem,
    MetricValue,
)


class MarketSnapshot(BaseModel):
    """Salida de `PolygonClient`: precio y variación más recientes de un ticker."""

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ticker: str
    asset_class: AssetClass
    fetched_at: datetime

    last_price: MetricValue
    day_open: MetricValue
    day_high: MetricValue
    day_low: MetricValue
    prev_close: MetricValue
    volume: MetricValue
    day_change_pct: MetricValue


class ReferenceTicker(BaseModel):
    """Una entrada del catálogo de `/v3/reference/tickers` de Polygon, ya parseada pero sin
    interpretar (.cursorrules §3). `primary_exchange` queda como el código MIC crudo que
    devuelve el proveedor (`XNAS`, `XNYS`…): normalizarlo a la bolsa del producto es decisión
    de la capa de aplicación (`app/services/ticker_catalog_service.py`), no de la ingesta.

    `asset_type` mapea el campo `type` de Polygon (`CS`, `ETF`, `ADRC`…) — se renombra porque
    `type` es builtin en Python, pero el valor no se toca.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    symbol: str
    name: str
    primary_exchange: str | None
    asset_type: str | None
    active: bool


class FilingReference(BaseModel):
    """Metadato de un filing SEC (10-K/10-Q), sin el contenido — el Nodo 2 decide si lo
    descarga e indexa.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ticker: str
    filing_type: str
    filed_at: datetime | None
    accepted_at: datetime | None
    filing_url: str | None
    final_document_url: str | None


class NewsSearchResult(BaseModel):
    """Salida de `TavilyClient`: artículos ya limpios de ruido HTML, listos para el RAG del
    Nodo 2. `articles` vacío + `status != OK` es una búsqueda fallida, no "sin noticias".
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    query: str
    fetched_at: datetime
    status: DataStatus
    articles: list[EvidenceItem] = Field(default_factory=list)


class GeminiGenerationResult(BaseModel):
    """Salida cruda de `GeminiClient`: el texto JSON generado, sin parsear ni validar contra
    ningún modelo de dominio — eso es responsabilidad del Nodo 3 (Spec.md §3.3), que sabe qué
    forma final espera (`AssetProjection`).
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    status: DataStatus
    raw_json_text: str | None
    finish_reason: str | None
    model: str
    generated_at: datetime
