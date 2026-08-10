"""Modelos Pydantic que reflejan la salida ya parseada (pero no interpretada) de cada
proveedor externo (.cursorrules §3: la ingesta parsea y devuelve el modelo crudo, nunca
decide). Reutilizan `MetricValue`/`DataStatus` de `validation/domain_models.py` para marcar
explícitamente ausencia de dato campo por campo, en vez de rellenar con un valor por defecto.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Any

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


class OhlcBar(BaseModel):
    """Una vela de `/v2/aggs/ticker/{ticker}/range/...` de Polygon: apertura, máximo, mínimo,
    cierre y volumen de un período.

    A diferencia de `MarketSnapshot`, acá los campos son `Decimal` planos y no `MetricValue`: una
    vela a la que le falte un precio no es una vela degradada, es una vela inválida — no se puede
    dibujar ni escalar el eje con un hueco. El parseo descarta la entrada incompleta en vez de
    propagarla con nulls (ver `_parse_ohlc_bar`), así que todo lo que sale de acá ya está completo.

    `timestamp_ms` queda en milisegundos, como lo manda el proveedor: convertirlo a segundos o a
    `datetime` es decisión de la capa que lo consume, no de la ingesta (.cursorrules §3).
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    timestamp_ms: int
    open: Decimal
    high: Decimal
    low: Decimal
    close: Decimal
    volume: Decimal


class MarketMover(BaseModel):
    """Una entrada de `/v2/snapshot/locale/us/markets/stocks/{gainers|losers}` de Polygon: un
    ticker entre los que más subieron o bajaron en la jornada.

    No trae bolsa: el endpoint de movers de Polygon devuelve el universo de acciones de US sin
    decir en qué mercado cotiza cada símbolo. Resolver eso es decisión de la capa de aplicación
    (`app/services/market_summary_service.py` lo cruza contra el catálogo local `Ticker`), no de
    la ingesta (.cursorrules §3).

    `last_price`/`day_change_pct` son `MetricValue` y no floats por la misma razón que en
    `MarketSnapshot`: un mover al que el proveedor no le mandó precio tiene que poder decir
    "no disponible" en vez de aparecer con un 0 que se lee como un dato real.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ticker: str
    last_price: MetricValue
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


class FinancialStatements(BaseModel):
    """Los tres estados contables de un símbolo, TAL COMO los devuelve el proveedor.

    Las filas quedan como `dict` sin tipar a propósito: cada endpoint de FMP trae decenas de líneas
    con nombres que varían entre la API legacy y la `stable`, y declarar un modelo por estado
    obligaría a elegir un subconjunto acá — donde no se sabe qué va a necesitar el consumidor — y a
    tirar el resto. La interpretación (qué línea es "ingresos", qué umbral es una bandera roja) es
    decisión de la capa de aplicación (.cursorrules §3).

    Cada lista puede venir vacía por separado: un balance general disponible sin flujo de caja
    permite igual la mitad del análisis, y esa asimetría es información que el servicio declara.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ticker: str

    # `annual` o `quarter`, tal como se le pidió al proveedor. Viaja con los datos porque un margen
    # trimestral y uno anual no se comparan entre sí.
    period: str

    income: list[dict[str, Any]]
    balance: list[dict[str, Any]]
    cash_flow: list[dict[str, Any]]

    @property
    def is_empty(self) -> bool:
        return not (self.income or self.balance or self.cash_flow)


class CompanyProfile(BaseModel):
    """Perfil de la empresa según FMP `/profile`: sector e industria en el vocabulario del
    proveedor, sin interpretar.

    `sector` e `industry` son `str | None` y no un enum: el vocabulario lo define el proveedor
    (`Technology`, `Consumer Cyclical`…) y normalizarlo al del producto es decisión de la capa de
    aplicación (.cursorrules §3). `None` es un caso normal, no un error — un ETF o un ADR pueden no
    tener sector asignado.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ticker: str
    company_name: str | None
    sector: str | None
    industry: str | None


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
