"""Servicio de `GET /api/v1/tickers/{ticker}/intelligence` — la Ficha de Inteligencia Profunda.

Orquesta tres fuentes que fallan de forma independiente y las compone en una respuesta que siempre
tiene forma válida (.cursorrules §2):

  1. **Fundamentales** — `FMPClient.get_financial_metrics`. Cada ratio ya viene como `MetricValue`
     con su propio status, así que un hueco puntual se declara por ratio, no por bloque entero.
  2. **Corpus RAG** — noticias (`TavilyClient`) y filings 10-K/10-Q (`FMPClient`), en paralelo.
  3. **Síntesis y proyecciones** — una única llamada a Gemini sobre (1) y (2), con salida forzada a
     `response_schema`.

Reglas de degradación, en orden de importancia:
  - **Sin evidencia no se pide síntesis.** Pedirle a un modelo que sintetice reportes que no tiene
    es pedirle que los invente, y esta Ficha es justamente donde una alucinación costaría más caro.
  - Los fundamentales son independientes de la síntesis: sin Gemini, la Ficha sigue mostrando los
    ratios y el semáforo de salud financiera (que se calcula en código, ver
    `_score_financial_health`).
  - Todo fallo se traduce a un `availability` + `degradation_reason` legible por bloque. Nunca a un
    5xx: el cliente tiene que poder pintar la Ficha parcial.

La caché es por ticker con TTL: la Ficha es cara (una llamada al LLM más cuatro a proveedores) y no
cambia de sentido en minutos.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Any, Literal, TypeVar

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from app.schemas.intelligence import (
    ConfidenceLevel,
    ConvictionLevel,
    DataAvailability,
    FinancialHealth,
    Fundamentals,
    LongTermProjection,
    MediumTermProjection,
    Projections,
    RagSummary,
    RatioValue,
    ScenarioOutlook,
    ShortTermProjection,
    SourceReference,
    TickerIntelligence,
    TrendDirection,
)
from src.ingestion.fmp_client import FMPClient
from src.ingestion.gemini_client import GeminiClient
from src.ingestion.tavily_client import TavilyClient
from src.validation.domain_models import (
    DataStatus,
    EvidenceItem,
    FinancialMetrics,
    MetricValue,
)

logger = logging.getLogger(__name__)

_PROMPT_PATH = (
    Path(__file__).resolve().parent.parent.parent
    / "prompts"
    / "deep_intelligence_system_prompt.md"
)

_REASON_NO_FMP = "Los fundamentales no están configurados en este entorno (falta FMP_API_KEY en .env)."
_REASON_FMP_FAILED = "No se pudieron obtener los fundamentales en este momento."
_REASON_NO_EVIDENCE_SOURCES = (
    "La síntesis de reportes no está configurada en este entorno (faltan TAVILY_API_KEY y/o "
    "FMP_API_KEY en .env)."
)
_REASON_NO_EVIDENCE = (
    "No se encontraron reportes ni noticias recientes para este activo, así que no hay material "
    "que sintetizar."
)
_REASON_NO_GEMINI = (
    "El análisis con IA no está configurado en este entorno (falta GEMINI_API_KEY en .env); se "
    "muestran los fundamentales sin síntesis ni proyecciones."
)
_REASON_GEMINI_FAILED = (
    "No se pudo generar el análisis con IA en este momento (falló la consulta al modelo); los "
    "fundamentales son datos reales."
)
_REASON_GEMINI_INVALID = "El modelo devolvió un análisis que no se pudo interpretar; los fundamentales son datos reales."
_REASON_NO_SYNTHESIS_WITHOUT_EVIDENCE = (
    "No se pidió síntesis al modelo porque no hay reportes ni noticias que respalden el análisis: "
    "sintetizar sin fuentes sería inventarlas."
)


# --- Esquema de salida que se le exige al LLM -----------------------------------------------
# Enums declarados en el schema (no solo en el prompt) para que el proveedor los respete en el
# modo JSON. Igual se re-valida en Python: no se confía en que lo cumpla (ver `_coerce_enum`).
_RESPONSE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "rag_summary": {
            "type": "object",
            "properties": {
                "headline": {"type": "string"},
                "key_points": {"type": "array", "items": {"type": "string"}},
                "risks": {"type": "array", "items": {"type": "string"}},
                "sources_used": {"type": "array", "items": {"type": "string"}},
            },
            "required": ["headline", "key_points", "risks"],
        },
        "short_term": {
            "type": "object",
            "properties": {
                "trend": {"type": "string", "enum": ["ALCISTA", "LATERAL", "BAJISTA"]},
                "confidence": {"type": "string", "enum": ["BAJA", "MEDIA", "ALTA"]},
                "argument": {"type": "string"},
                "evidence_refs": {"type": "array", "items": {"type": "string"}},
            },
            "required": ["trend", "confidence", "argument"],
        },
        "medium_term": {
            "type": "object",
            "properties": {
                "base_case": {"$ref": "#/$defs/scenario"},
                "bull_case": {"$ref": "#/$defs/scenario"},
                "bear_case": {"$ref": "#/$defs/scenario"},
                "catalysts": {"type": "array", "items": {"type": "string"}},
                "confidence": {"type": "string", "enum": ["BAJA", "MEDIA", "ALTA"]},
                "evidence_refs": {"type": "array", "items": {"type": "string"}},
            },
            "required": ["base_case", "bull_case", "bear_case"],
        },
        "long_term": {
            "type": "object",
            "properties": {
                "thesis": {"type": "string"},
                "conviction": {
                    "type": "string",
                    "enum": ["BAJA", "MODERADA", "ALTA"],
                },
                "supporting_factors": {"type": "array", "items": {"type": "string"}},
                "invalidation_triggers": {"type": "array", "items": {"type": "string"}},
                "evidence_refs": {"type": "array", "items": {"type": "string"}},
            },
            "required": ["thesis", "conviction", "invalidation_triggers"],
        },
    },
    "required": ["rag_summary", "short_term", "medium_term", "long_term"],
    "$defs": {
        "scenario": {
            "type": "object",
            "properties": {
                "narrative": {"type": "string"},
                "probability_pct": {"type": "number"},
            },
            "required": ["narrative"],
        }
    },
}


class _LLMScenario(BaseModel):
    model_config = ConfigDict(strict=True, extra="ignore")

    narrative: str
    probability_pct: float | None = None


class _LLMRagSummary(BaseModel):
    model_config = ConfigDict(strict=True, extra="ignore")

    headline: str
    key_points: list[str] = Field(default_factory=list)
    risks: list[str] = Field(default_factory=list)
    sources_used: list[str] = Field(default_factory=list)


class _LLMShortTerm(BaseModel):
    model_config = ConfigDict(strict=True, extra="ignore")

    trend: str
    confidence: str
    argument: str
    evidence_refs: list[str] = Field(default_factory=list)


class _LLMMediumTerm(BaseModel):
    model_config = ConfigDict(strict=True, extra="ignore")

    base_case: _LLMScenario
    bull_case: _LLMScenario
    bear_case: _LLMScenario
    catalysts: list[str] = Field(default_factory=list)
    confidence: str = "MEDIA"
    evidence_refs: list[str] = Field(default_factory=list)


class _LLMLongTerm(BaseModel):
    model_config = ConfigDict(strict=True, extra="ignore")

    thesis: str
    conviction: str
    supporting_factors: list[str] = Field(default_factory=list)
    invalidation_triggers: list[str] = Field(default_factory=list)
    evidence_refs: list[str] = Field(default_factory=list)


class _LLMOutput(BaseModel):
    """Forma exacta de lo que se le pide al LLM.

    `extra="ignore"` y no `"forbid"`: si el proveedor agrega un campo que no pedimos, descartarlo es
    preferible a tirar toda la Ficha por un extra inofensivo. Los campos que SÍ nos importan siguen
    siendo obligatorios, así que una respuesta incompleta igual falla la validación.
    """

    model_config = ConfigDict(strict=True, extra="ignore")

    rag_summary: _LLMRagSummary
    short_term: _LLMShortTerm
    medium_term: _LLMMediumTerm
    long_term: _LLMLongTerm


def _load_system_prompt() -> str:
    try:
        return _PROMPT_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(
            f"No se pudo leer el system prompt de inteligencia profunda en {_PROMPT_PATH}."
        ) from exc


# --- Fundamentales --------------------------------------------------------------------------


def _ratio(metric: MetricValue, label: str, unit: str | None) -> RatioValue:
    """Convierte un `MetricValue` del motor al `RatioValue` que expone la API.

    Un status distinto de OK se trata como ausente: el valor que trae un `MetricValue` degradado no
    es confiable, y mostrarlo igual sería peor que decir "no disponible".
    """

    value = (
        float(metric.value)
        if metric.value is not None and metric.status == DataStatus.OK
        else None
    )
    return RatioValue(label=label, value=value, unit=unit)


def _as_float(metric: MetricValue) -> float | None:
    if metric.value is None or metric.status != DataStatus.OK:
        return None
    return float(metric.value)


def _score_financial_health(
    metrics: FinancialMetrics,
) -> tuple[FinancialHealth, list[str]]:
    """Semáforo de salud financiera a partir de apalancamiento, liquidez, rentabilidad y caja.

    Determinístico y en código, no delegado al LLM: son umbrales sobre números que ya tenemos, y
    tenerlos acá los vuelve auditables y reproducibles. Los cortes son convenciones amplias de
    análisis fundamental, no una fórmula propietaria — están explícitos justamente para que se
    puedan discutir y ajustar.

    Devuelve `INDETERMINADA` si no hay al menos tres señales: un veredicto sobre un solo ratio
    diría más sobre lo que falta que sobre la empresa.
    """

    positives: list[str] = []
    negatives: list[str] = []
    notes: list[str] = []

    debt_to_equity = _as_float(metrics.debt_to_equity)
    if debt_to_equity is not None:
        if debt_to_equity < 1.0:
            positives.append("leverage")
            notes.append(f"Deuda/Equity de {debt_to_equity:.2f}x: apalancamiento bajo.")
        elif debt_to_equity <= 2.0:
            notes.append(
                f"Deuda/Equity de {debt_to_equity:.2f}x: apalancamiento moderado."
            )
        else:
            negatives.append("leverage")
            notes.append(f"Deuda/Equity de {debt_to_equity:.2f}x: apalancamiento alto.")

    debt_to_ebitda = _as_float(metrics.debt_to_ebitda)
    if debt_to_ebitda is not None:
        if debt_to_ebitda < 3.0:
            positives.append("debt_coverage")
            notes.append(
                f"Deuda neta/EBITDA de {debt_to_ebitda:.2f}x: la deuda es cubrible con la "
                "generación operativa."
            )
        elif debt_to_ebitda > 4.0:
            negatives.append("debt_coverage")
            notes.append(
                f"Deuda neta/EBITDA de {debt_to_ebitda:.2f}x: la deuda pesa sobre la "
                "generación operativa."
            )

    current_ratio = _as_float(metrics.current_ratio)
    if current_ratio is not None:
        if current_ratio >= 1.5:
            positives.append("liquidity")
            notes.append(f"Ratio corriente de {current_ratio:.2f}x: liquidez holgada.")
        elif current_ratio < 1.0:
            negatives.append("liquidity")
            notes.append(
                f"Ratio corriente de {current_ratio:.2f}x: el pasivo corriente supera al "
                "activo corriente."
            )

    free_cash_flow = _as_float(metrics.free_cash_flow)
    if free_cash_flow is not None:
        if free_cash_flow > 0:
            positives.append("cash_generation")
            notes.append("Flujo de caja libre positivo en el último período reportado.")
        else:
            negatives.append("cash_generation")
            notes.append("Flujo de caja libre negativo en el último período reportado.")

    operating_margin = _as_float(metrics.operating_margin_pct)
    if operating_margin is not None:
        # FMP devuelve márgenes como fracción (0.32) o como porcentaje (32) según el endpoint;
        # se normaliza para que el umbral signifique lo mismo en los dos casos.
        margin_pct = (
            operating_margin * 100 if abs(operating_margin) <= 1 else operating_margin
        )
        if margin_pct >= 15:
            positives.append("profitability")
            notes.append(f"Margen operativo de {margin_pct:.1f}%: rentabilidad sólida.")
        elif margin_pct < 0:
            negatives.append("profitability")
            notes.append(f"Margen operativo de {margin_pct:.1f}%: opera a pérdida.")

    signals = len(positives) + len(negatives)
    if signals < 3:
        return FinancialHealth.INDETERMINADA, notes

    score = len(positives) - len(negatives)
    if score >= 3:
        health = FinancialHealth.SOLIDA
    elif score >= 1:
        health = FinancialHealth.ADECUADA
    elif score >= -1:
        health = FinancialHealth.AJUSTADA
    else:
        health = FinancialHealth.DEBIL
    return health, notes


def build_fundamentals(
    metrics: FinancialMetrics | None, *, reason: str
) -> Fundamentals:
    """Arma el bloque de fundamentales, con o sin métricas.

    Un único camino para los dos casos: con `metrics=None` todos los ratios quedan vacíos y el
    bloque va `UNAVAILABLE` con `reason`. Tener una sola función evita que la versión vacía se
    olvide de un ratio que la versión con datos sí trae.

    Cada ratio se nombra explícitamente en vez de recorrer una tabla con `getattr`: los nombres del
    modelo del motor y los de la API no coinciden (`price_earnings_ratio` contra `price_earnings`),
    y resolverlos por string le saca al type checker la posibilidad de detectar un typo — que acá
    significaría un ratio silenciosamente vacío en la Ficha.
    """

    def ratio(metric: MetricValue | None, label: str, unit: str | None) -> RatioValue:
        if metric is None:
            return RatioValue(label=label, value=None, unit=unit)
        return _ratio(metric, label, unit)

    price_earnings = ratio(
        metrics.price_earnings_ratio if metrics else None, "P/E", "x"
    )
    price_earnings_growth = ratio(
        metrics.price_earnings_growth_ratio if metrics else None, "PEG", "x"
    )
    debt_to_equity = ratio(
        metrics.debt_to_equity if metrics else None, "Deuda/Equity", "x"
    )
    debt_to_ebitda = ratio(
        metrics.debt_to_ebitda if metrics else None, "Deuda neta/EBITDA", "x"
    )
    free_cash_flow = ratio(
        metrics.free_cash_flow if metrics else None, "Flujo de caja libre", "USD"
    )
    free_cash_flow_yield = ratio(
        metrics.free_cash_flow_yield_pct if metrics else None, "FCF yield", "%"
    )
    gross_margin = ratio(
        metrics.gross_margin_pct if metrics else None, "Margen bruto", "%"
    )
    operating_margin = ratio(
        metrics.operating_margin_pct if metrics else None, "Margen operativo", "%"
    )
    return_on_equity = ratio(
        metrics.return_on_equity_pct if metrics else None, "ROE", "%"
    )
    current_ratio = ratio(
        metrics.current_ratio if metrics else None, "Ratio corriente", "x"
    )
    revenue_growth = ratio(
        metrics.revenue_growth_yoy_pct if metrics else None,
        "Crecimiento de ingresos YoY",
        "%",
    )

    all_ratios = (
        price_earnings,
        price_earnings_growth,
        debt_to_equity,
        debt_to_ebitda,
        free_cash_flow,
        free_cash_flow_yield,
        gross_margin,
        operating_margin,
        return_on_equity,
        current_ratio,
        revenue_growth,
    )

    health, notes = (
        _score_financial_health(metrics)
        if metrics is not None
        else (FinancialHealth.INDETERMINADA, [])
    )

    present = sum(1 for item in all_ratios if item.value is not None)
    total = len(all_ratios)
    if present == 0:
        availability = DataAvailability.UNAVAILABLE
        degradation: str | None = reason
    elif present < total:
        availability = DataAvailability.PARTIAL
        degradation = (
            f"{total - present} de {total} ratios no están disponibles para este activo "
            "(el proveedor no los devolvió)."
        )
    else:
        availability = DataAvailability.AVAILABLE
        degradation = None

    return Fundamentals(
        availability=availability,
        as_of=metrics.fetched_at if metrics is not None else None,
        period=metrics.fundamentals_period if metrics is not None else None,
        price_earnings=price_earnings,
        price_earnings_growth=price_earnings_growth,
        debt_to_equity=debt_to_equity,
        debt_to_ebitda=debt_to_ebitda,
        free_cash_flow=free_cash_flow,
        free_cash_flow_yield_pct=free_cash_flow_yield,
        gross_margin_pct=gross_margin,
        operating_margin_pct=operating_margin,
        return_on_equity_pct=return_on_equity,
        current_ratio=current_ratio,
        revenue_growth_yoy_pct=revenue_growth,
        financial_health=health,
        financial_health_notes=notes,
        degradation_reason=degradation,
    )


# --- Normalización de la salida del modelo --------------------------------------------------

# Acotado a `Enum` y no libre: `_coerce_enum` construye `options(valor)`, que solo tiene sentido
# para un enum.
_EnumT = TypeVar("_EnumT", bound=Enum)


def _coerce_enum(raw: str, options: type[_EnumT], fallback: _EnumT) -> _EnumT:
    """Mapea un string del modelo a un enum, con fallback si no matchea.

    El `response_schema` ya declara los enums, pero no se confía en que el proveedor los respete: un
    valor libre llegaría hasta la UI y rompería el pintado por tendencia/convicción. El fallback es
    siempre el valor más conservador (LATERAL, BAJA), así que un desvío del modelo degrada la
    afirmación en vez de inventar una más fuerte.
    """

    try:
        return options(raw.strip().upper())
    except ValueError:
        logger.warning(
            "intelligence_unexpected_enum_value",
            extra={"value": raw, "enum": options.__name__},
        )
        return fallback


def _scenario(raw: _LLMScenario, label: str) -> ScenarioOutlook:
    probability = raw.probability_pct
    # Una probabilidad fuera de rango es un dato roto, no algo a recortar a 0/100: se descarta y el
    # escenario queda sin número, que el schema permite explícitamente.
    if probability is not None and not 0 <= probability <= 100:
        logger.warning(
            "intelligence_probability_out_of_range", extra={"value": probability}
        )
        probability = None
    return ScenarioOutlook(
        label=label, narrative=raw.narrative, probability_pct=probability
    )


# --- Servicio -------------------------------------------------------------------------------


class TickerIntelligenceService:
    """Todos los clientes son opcionales: cada uno ausente degrada su propio bloque y nada más.

    `fmp_client=None` deja los fundamentales vacíos; `gemini_client=None` deja síntesis y
    proyecciones vacías pero conserva los ratios; sin Tavily ni FMP no hay corpus y entonces
    tampoco se le pide síntesis al modelo (ver la regla en el docstring del módulo).
    """

    def __init__(
        self,
        *,
        fmp_client: FMPClient | None = None,
        tavily_client: TavilyClient | None = None,
        gemini_client: GeminiClient | None = None,
        cache_ttl_seconds: float = 3600.0,
        news_max_results: int = 5,
        filings_per_type: int = 2,
        system_prompt: str | None = None,
    ) -> None:
        self._fmp = fmp_client
        self._tavily = tavily_client
        self._gemini = gemini_client
        self._cache_ttl_seconds = cache_ttl_seconds
        self._news_max_results = news_max_results
        self._filings_per_type = filings_per_type
        self._system_prompt = system_prompt or _load_system_prompt()

        self._cache: dict[str, tuple[float, TickerIntelligence]] = {}
        # Un lock POR TICKER, no uno global: dos usuarios abriendo fichas de activos distintos no
        # tienen por qué esperarse entre sí, pero dos abriendo la misma sí deben compartir una
        # única corrida (que es lo que la caché existe para lograr).
        self._locks: dict[str, asyncio.Lock] = {}

    async def get_intelligence(
        self,
        ticker: str,
        *,
        company_name: str | None = None,
        force_refresh: bool = False,
    ) -> TickerIntelligence:
        normalized = ticker.upper()

        if not force_refresh:
            cached = self._fresh_cache(normalized)
            if cached is not None:
                return cached

        lock = self._locks.setdefault(normalized, asyncio.Lock())
        async with lock:
            if not force_refresh:
                # Re-chequeo adentro del lock: mientras se esperaba, otra corrida pudo haberla
                # completado, y repetir la llamada al modelo sería el gasto que se quiere evitar.
                cached = self._fresh_cache(normalized)
                if cached is not None:
                    return cached

            result = await self._build(normalized, company_name)
            self._cache[normalized] = (time.monotonic(), result)
            return result

    def _fresh_cache(self, ticker: str) -> TickerIntelligence | None:
        """`time.monotonic` y no `datetime.now`: la caché mide tiempo transcurrido, y un ajuste de
        reloj del sistema no debería invalidarla ni eternizarla.
        """

        entry = self._cache.get(ticker)
        if entry is None:
            return None
        cached_at, value = entry
        if time.monotonic() - cached_at > self._cache_ttl_seconds:
            return None
        return value.model_copy(update={"served_from_cache": True})

    async def _build(self, ticker: str, company_name: str | None) -> TickerIntelligence:
        metrics, evidence, evidence_reason = await asyncio.gather(
            self._fetch_metrics(ticker),
            self._fetch_evidence(ticker),
            self._evidence_reason(),
        )

        fundamentals = build_fundamentals(
            metrics,
            reason=_REASON_NO_FMP if self._fmp is None else _REASON_FMP_FAILED,
        )

        rag_summary, projections = await self._synthesize(
            ticker, fundamentals, evidence, evidence_reason
        )

        return TickerIntelligence(
            ticker=ticker,
            company_name=company_name,
            generated_at=datetime.now(timezone.utc),
            fundamentals=fundamentals,
            rag_summary=rag_summary,
            projections=projections,
        )

    async def _evidence_reason(self) -> str | None:
        """Motivo de que no haya corpus, si ninguna fuente está configurada. Es `async` solo para
        poder entrar en el mismo `gather` que las otras dos.
        """

        if self._tavily is None and self._fmp is None:
            return _REASON_NO_EVIDENCE_SOURCES
        return None

    async def _fetch_metrics(self, ticker: str) -> FinancialMetrics | None:
        if self._fmp is None:
            return None
        try:
            return await self._fmp.get_financial_metrics(ticker)
        except Exception as exc:  # noqa: BLE001 — `FMPClient` degrada sus errores de proveedor a
            # `MetricValue` con status ERROR_API sin lanzar; esto cubre un bug inesperado y se
            # registra explícito en vez de tumbar la Ficha (.cursorrules §2).
            logger.warning(
                "intelligence_fundamentals_failed",
                extra={"ticker": ticker, "error": str(exc)},
            )
            return None

    async def _fetch_evidence(self, ticker: str) -> list[EvidenceItem]:
        """Corpus para la síntesis: noticias recientes más los últimos 10-K/10-Q.

        Las tres búsquedas van en paralelo y cada una degrada sola. Los filings entran como
        referencia (título y URL), no con su texto: descargar e indexar el 10-K completo es trabajo
        del Nodo 2 del motor y no corresponde hacerlo en el camino de un request HTTP.
        """

        tasks: list[Any] = []
        if self._tavily is not None:
            tasks.append(self._fetch_news(ticker))
        if self._fmp is not None:
            tasks.append(self._fetch_filings(ticker, "10-K"))
            tasks.append(self._fetch_filings(ticker, "10-Q"))

        if not tasks:
            return []

        results = await asyncio.gather(*tasks, return_exceptions=True)
        evidence: list[EvidenceItem] = []
        for result in results:
            if isinstance(result, BaseException):
                logger.warning(
                    "intelligence_evidence_source_failed",
                    extra={"ticker": ticker, "error": str(result)},
                )
                continue
            evidence.extend(result)
        return evidence

    async def _fetch_news(self, ticker: str) -> list[EvidenceItem]:
        tavily = self._tavily
        if tavily is None:
            return []
        result = await tavily.search_news(
            f"{ticker} resultados trimestrales guidance riesgos",
            max_results=self._news_max_results,
        )
        if result.status != DataStatus.OK:
            return []

        # Se re-etiquetan los `ref_id`. `TavilyClient` los genera como
        # `tavily:<timestamp ISO>:<índice>`, que sirve para trazar dentro del motor pero es mal
        # material para que un LLM lo cite: es largo, tiene dos puntos y cambia en cada búsqueda.
        # Un `NEWS-1` corto y estable hace que la cita sea confiable y que el descarte de refs
        # inventadas (`_valid_refs`) distinga de verdad entre citado y alucinado.
        return [
            article.model_copy(update={"ref_id": f"NEWS-{index + 1}"})
            for index, article in enumerate(result.articles)
        ]

    async def _fetch_filings(
        self, ticker: str, filing_type: Literal["10-K", "10-Q"]
    ) -> list[EvidenceItem]:
        # `Literal` y no `str`: tanto `list_recent_filings` como `EvidenceItem.source_type` esperan
        # valores cerrados, y tiparlo acá deja que el chequeo los propague en vez de necesitar un
        # `type: ignore` en la construcción.
        fmp = self._fmp
        if fmp is None:
            return []
        filings = await fmp.list_recent_filings(
            ticker, filing_type, limit=self._filings_per_type
        )
        source_type: Literal["SEC_10K", "SEC_10Q"] = (
            "SEC_10K" if filing_type == "10-K" else "SEC_10Q"
        )
        return [
            EvidenceItem(
                ref_id=f"{source_type}-{index + 1}",
                source_type=source_type,
                url=filing.final_document_url or filing.filing_url,
                published_at=filing.filed_at,
                # Sin el contenido del filing, el "extracto" es su identificación. Se dice
                # explícitamente que es una referencia para que el modelo no la cite como si
                # hubiera leído el documento.
                excerpt=(
                    f"Referencia a {filing.filing_type} de {filing.ticker} "
                    f"(solo metadato, sin contenido indexado)."
                ),
            )
            for index, filing in enumerate(filings)
        ]

    async def _synthesize(
        self,
        ticker: str,
        fundamentals: Fundamentals,
        evidence: list[EvidenceItem],
        evidence_reason: str | None,
    ) -> tuple[RagSummary, Projections]:
        if (gemini := self._gemini) is None:
            return (
                RagSummary(
                    availability=DataAvailability.UNAVAILABLE,
                    degradation_reason=_REASON_NO_GEMINI,
                ),
                Projections(
                    availability=DataAvailability.UNAVAILABLE,
                    degradation_reason=_REASON_NO_GEMINI,
                ),
            )

        if not evidence:
            # La regla más importante del servicio: sin fuentes no se pide síntesis.
            reason = evidence_reason or _REASON_NO_EVIDENCE
            logger.warning(
                "intelligence_no_evidence_skipping_llm", extra={"ticker": ticker}
            )
            return (
                RagSummary(
                    availability=DataAvailability.UNAVAILABLE,
                    degradation_reason=reason,
                ),
                Projections(
                    availability=DataAvailability.UNAVAILABLE,
                    degradation_reason=_REASON_NO_SYNTHESIS_WITHOUT_EVIDENCE,
                ),
            )

        result = await gemini.generate_structured_json(
            system_instruction=self._system_prompt,
            user_content=_build_user_content(ticker, fundamentals, evidence),
            response_schema=_RESPONSE_SCHEMA,
        )

        if result.status != DataStatus.OK or result.raw_json_text is None:
            logger.warning("intelligence_gemini_call_failed", extra={"ticker": ticker})
            return _degraded_synthesis(_REASON_GEMINI_FAILED)

        try:
            parsed = json.loads(result.raw_json_text)
            # strict=False solo en esta frontera JSON, mismo caso que `chat_service.py` y
            # `market_summary_service.py`: JSON no tiene tipo nativo para Decimal ni Enum.
            output = _LLMOutput.model_validate(parsed, strict=False)
        except (json.JSONDecodeError, ValidationError) as exc:
            logger.warning(
                "intelligence_output_invalid",
                extra={"ticker": ticker, "error": str(exc)},
            )
            return _degraded_synthesis(_REASON_GEMINI_INVALID)

        return _compose_synthesis(output, evidence)


def _degraded_synthesis(reason: str) -> tuple[RagSummary, Projections]:
    return (
        RagSummary(
            availability=DataAvailability.UNAVAILABLE, degradation_reason=reason
        ),
        Projections(
            availability=DataAvailability.UNAVAILABLE, degradation_reason=reason
        ),
    )


def _compose_synthesis(
    output: _LLMOutput, evidence: list[EvidenceItem]
) -> tuple[RagSummary, Projections]:
    by_ref = {item.ref_id: item for item in evidence}

    # Solo se exponen las fuentes que el modelo dijo haber usado Y que existen de verdad en el
    # corpus: si citó un ref_id que no le pasamos, se lo descarta en vez de mostrarle al usuario
    # una fuente inventada.
    used = [by_ref[ref] for ref in output.rag_summary.sources_used if ref in by_ref]
    if not used:
        # Sin refs válidas se listan todas las que se le pasaron: es más honesto decir "estas son
        # las fuentes del análisis" que dejar la sección sin trazabilidad.
        used = evidence

    rag_summary = RagSummary(
        availability=DataAvailability.AVAILABLE,
        headline=output.rag_summary.headline,
        key_points=output.rag_summary.key_points,
        risks=output.rag_summary.risks,
        sources=[
            SourceReference(
                ref_id=item.ref_id,
                source_type=item.source_type,
                title=item.excerpt[:120] or None,
                url=item.url,
                published_at=item.published_at,
            )
            for item in used
        ],
    )

    projections = Projections(
        availability=DataAvailability.AVAILABLE,
        short_term=ShortTermProjection(
            trend=_coerce_enum(
                output.short_term.trend, TrendDirection, TrendDirection.LATERAL
            ),
            confidence=_coerce_enum(
                output.short_term.confidence, ConfidenceLevel, ConfidenceLevel.BAJA
            ),
            argument=output.short_term.argument,
            evidence_refs=_valid_refs(output.short_term.evidence_refs, by_ref),
        ),
        medium_term=MediumTermProjection(
            base_case=_scenario(output.medium_term.base_case, "BASE"),
            bull_case=_scenario(output.medium_term.bull_case, "ALCISTA"),
            bear_case=_scenario(output.medium_term.bear_case, "BAJISTA"),
            catalysts=output.medium_term.catalysts,
            confidence=_coerce_enum(
                output.medium_term.confidence, ConfidenceLevel, ConfidenceLevel.BAJA
            ),
            evidence_refs=_valid_refs(output.medium_term.evidence_refs, by_ref),
        ),
        long_term=LongTermProjection(
            thesis=output.long_term.thesis,
            conviction=_coerce_enum(
                output.long_term.conviction, ConvictionLevel, ConvictionLevel.BAJA
            ),
            supporting_factors=output.long_term.supporting_factors,
            invalidation_triggers=output.long_term.invalidation_triggers,
            evidence_refs=_valid_refs(output.long_term.evidence_refs, by_ref),
        ),
    )
    return rag_summary, projections


def _valid_refs(refs: list[str], by_ref: dict[str, EvidenceItem]) -> list[str]:
    """Descarta los `ref_id` que el modelo citó pero que no están en el corpus. Una cita a una
    fuente inexistente es una alucinación con formato de rigor, que es la peor clase.
    """

    return [ref for ref in refs if ref in by_ref]


def _format_ratio(ratio: RatioValue) -> str:
    if ratio.value is None:
        return f"  - {ratio.label}: no disponible"
    if ratio.unit == "USD":
        return f"  - {ratio.label}: USD {ratio.value:,.0f}"
    if ratio.unit == "%":
        # Los márgenes llegan como fracción o como porcentaje según el endpoint de FMP; se
        # normaliza para que el prompt no reciba "0.32%" cuando el margen es del 32%.
        value = ratio.value * 100 if abs(ratio.value) <= 1 else ratio.value
        return f"  - {ratio.label}: {value:.2f}%"
    return f"  - {ratio.label}: {ratio.value:.2f}{ratio.unit or ''}"


def _build_user_content(
    ticker: str, fundamentals: Fundamentals, evidence: list[EvidenceItem]
) -> str:
    """Arma los bloques `<fundamentals>` y `<evidence>` que el prompt exige como única fuente.

    Los ratios ausentes se declaran como "no disponible" en vez de omitirse: si el bloque no los
    mencionara, el modelo no tendría forma de saber que faltan y podría estimarlos.
    """

    ratios_block = "\n".join(_format_ratio(ratio) for ratio in fundamentals.ratios)
    health_notes = (
        "\n".join(f"  - {note}" for note in fundamentals.financial_health_notes)
        or "  - (sin señales suficientes)"
    )

    evidence_block = (
        "\n".join(
            f"  [{item.ref_id}] ({item.source_type}"
            + (
                f", {item.published_at.date().isoformat()}"
                if item.published_at is not None
                else ""
            )
            + f") {item.excerpt}"
            for item in evidence
        )
        or "  (sin evidencia)"
    )

    return (
        f"<ticker>{ticker}</ticker>\n"
        "<fundamentals>\n"
        f"Período: {fundamentals.period or 'no informado'}\n"
        f"{ratios_block}\n"
        f"Salud financiera calculada: {fundamentals.financial_health.value}\n"
        f"{health_notes}\n"
        "</fundamentals>\n"
        "<evidence>\n"
        f"{evidence_block}\n"
        "</evidence>"
    )
