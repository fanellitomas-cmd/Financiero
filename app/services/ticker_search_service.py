"""Servicio de `POST /api/v1/tickers/search-nl` — búsqueda conversacional en lenguaje natural.

Tres etapas, con una frontera muy explícita entre lo que decide el modelo y lo que decide el
código (ver el docstring de `app/schemas/search.py`):

  1. **Interpretar** — Gemini traduce la consulta a `SearchCriteria` con salida forzada a
     `response_schema`. Todo lo que devuelve se re-valida en Python: los enums se mapean con
     fallback, los rangos invertidos se corrigen y los valores absurdos se descartan.
  2. **Filtrar el catálogo** — sector, bolsa y texto van a SQL sobre `Ticker`. Es lo barato y lo
     que acota el universo antes de gastar una sola llamada a un proveedor.
  3. **Filtrar por ratios** — solo si la consulta los pidió y solo sobre los candidatos que
     sobrevivieron al paso 2, con un tope duro de símbolos consultados.

El tope del paso 3 no es una optimización, es un límite de diseño: `get_financial_metrics` pega a
cinco endpoints de FMP por símbolo, así que una consulta que matchee 200 candidatos serían mil
requests dentro de un request HTTP. Se consulta un prefijo acotado y se declara en la respuesta
cuántos candidatos se evaluaron.

Degradación (.cursorrules §2):
  - **Sin Gemini** → no se inventan criterios: la consulta se usa como búsqueda de texto sobre
    símbolo y nombre, y la respuesta lo declara con `criteria_source=TEXT_FALLBACK`.
  - **Sin FMP** → los criterios numéricos no se aplican y viajan en `unapplied_criteria`. Es la
    degradación más delicada del endpoint: una lista filtrada solo por sector, presentada como si
    cumpliera "P/E menor a 20", sería una respuesta falsa.
"""

from __future__ import annotations

import asyncio
import json
import logging
import math
from pathlib import Path
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, ValidationError
from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.enums import ExchangeType
from app.models.ticker import Ticker
from app.schemas.portfolio_audit import PortfolioSector, sector_label
from app.schemas.search import (
    CriteriaSource,
    NaturalSearchResponse,
    NumericRange,
    SearchCriteria,
    TickerMatch,
)
from app.services.portfolio_audit_service import (
    normalize_sector,
    provider_sector_keys,
)
from src.ingestion.fmp_client import FMPClient
from src.ingestion.gemini_client import GeminiClient
from src.validation.domain_models import DataStatus, FinancialMetrics, MetricValue

logger = logging.getLogger(__name__)

_PROMPT_PATH = (
    Path(__file__).resolve().parent.parent.parent
    / "prompts"
    / "ticker_search_system_prompt.md"
)

_REASON_NO_GEMINI = (
    "La interpretación con IA no está configurada en este entorno (falta GEMINI_API_KEY en .env); "
    "se buscó por coincidencia de texto en el símbolo y el nombre."
)
_REASON_GEMINI_FAILED = (
    "No se pudo interpretar la consulta con IA en este momento (falló la consulta al modelo); se "
    "buscó por coincidencia de texto en el símbolo y el nombre."
)
_REASON_GEMINI_INVALID = (
    "El modelo devolvió una interpretación que no se pudo leer; se buscó por coincidencia de texto "
    "en el símbolo y el nombre."
)
_REASON_NO_METRICS = (
    "Los ratios financieros no están configurados en este entorno (falta FMP_API_KEY en .env), así "
    "que los filtros numéricos no se aplicaron: estos resultados NO cumplen necesariamente esa "
    "parte de tu búsqueda."
)
_REASON_EMPTY_CRITERIA = (
    "No se pudo estructurar la consulta en criterios de búsqueda; se buscó por coincidencia de "
    "texto en el símbolo y el nombre."
)

_RESPONSE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "interpretation": {"type": "string"},
        "sectors": {"type": "array", "items": {"type": "string"}},
        "exchanges": {"type": "array", "items": {"type": "string"}},
        "price_earnings_min": {"type": "number"},
        "price_earnings_max": {"type": "number"},
        "debt_to_equity_min": {"type": "number"},
        "debt_to_equity_max": {"type": "number"},
        "return_on_equity_min_pct": {"type": "number"},
        "return_on_equity_max_pct": {"type": "number"},
        "revenue_growth_min_pct": {"type": "number"},
        "revenue_growth_max_pct": {"type": "number"},
        "market_cap_min_usd": {"type": "number"},
        "market_cap_max_usd": {"type": "number"},
        "free_cash_flow_positive": {"type": "boolean"},
        "text_query": {"type": "string"},
    },
    "required": ["interpretation"],
}


class _LLMSearchCriteria(BaseModel):
    """Forma exacta de lo que se le pide al modelo.

    Todos los campos son planos y opcionales (nada de objetos anidados para los rangos): un
    `response_schema` chato es el que los proveedores respetan de forma más confiable, y armar el
    `NumericRange` a partir de dos escalares es trivial acá.

    `extra="ignore"`: si el proveedor agrega un campo que no pedimos, descartarlo es preferible a
    tirar la búsqueda entera por un extra inofensivo.
    """

    model_config = ConfigDict(strict=True, extra="ignore")

    interpretation: str = ""
    sectors: list[str] = Field(default_factory=list)
    exchanges: list[str] = Field(default_factory=list)
    price_earnings_min: float | None = None
    price_earnings_max: float | None = None
    debt_to_equity_min: float | None = None
    debt_to_equity_max: float | None = None
    return_on_equity_min_pct: float | None = None
    return_on_equity_max_pct: float | None = None
    revenue_growth_min_pct: float | None = None
    revenue_growth_max_pct: float | None = None
    market_cap_min_usd: float | None = None
    market_cap_max_usd: float | None = None
    free_cash_flow_positive: bool | None = None
    text_query: str | None = None


def _load_system_prompt() -> str:
    try:
        return _PROMPT_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(
            f"No se pudo leer el system prompt de la búsqueda NL en {_PROMPT_PATH}."
        ) from exc


def _range(minimum: float | None, maximum: float | None) -> NumericRange:
    """Arma un rango a partir de dos escalares del modelo, corrigiendo lo que venga mal.

    Un rango invertido (mínimo 30, máximo 10) es un error de interpretación del modelo, no una
    búsqueda imposible: se lo da vuelta en vez de devolver cero resultados sin explicación. Un
    valor no finito (NaN/infinito, que un JSON no estándar puede traer) se descarta — compararlo
    dejaría pasar todo o filtraría todo según el operador, sin que nada falle.
    """

    def clean(value: float | None) -> float | None:
        if value is None or not math.isfinite(value):
            return None
        return value

    low, high = clean(minimum), clean(maximum)
    if low is not None and high is not None and low > high:
        logger.warning(
            "search_nl_inverted_range", extra={"minimum": low, "maximum": high}
        )
        low, high = high, low
    return NumericRange(minimum=low, maximum=high)


def _coerce_sectors(raw: list[str]) -> list[PortfolioSector]:
    """Sectores del modelo -> vocabulario del producto, sin duplicados y en orden estable.

    Se aceptan tanto los códigos del producto (`TECNOLOGIA`) como los del proveedor
    (`Technology`): al modelo se le pide el primero, pero reconocer el segundo cuesta una línea y
    evita que una respuesta razonable se descarte por vocabulario.

    Lo que no matchea se descarta en silencio (con log): un sector inventado no puede filtrar nada,
    y arrastrarlo haría que la búsqueda no devuelva resultados sin motivo visible.
    """

    resolved: list[PortfolioSector] = []
    for value in raw:
        normalized = value.strip().upper().replace(" ", "_")
        sector = next(
            (item for item in PortfolioSector if item.value == normalized),
            None,
        )
        if sector is None:
            sector_from_provider = normalize_sector(value)
            sector = (
                sector_from_provider
                if sector_from_provider != PortfolioSector.SIN_CLASIFICAR
                else None
            )
        if sector is None:
            logger.warning("search_nl_unknown_sector", extra={"value": value})
            continue
        if sector not in resolved:
            resolved.append(sector)
    return resolved


def _coerce_exchanges(raw: list[str]) -> list[ExchangeType]:
    resolved: list[ExchangeType] = []
    for value in raw:
        try:
            exchange = ExchangeType(value.strip().upper())
        except ValueError:
            logger.warning("search_nl_unknown_exchange", extra={"value": value})
            continue
        # `OTHER` se descarta: es el cajón de las bolsas que el producto no ofrece, así que como
        # filtro no significa nada que el usuario haya podido pedir.
        if exchange != ExchangeType.OTHER and exchange not in resolved:
            resolved.append(exchange)
    return resolved


def build_criteria(output: _LLMSearchCriteria) -> SearchCriteria:
    text = (output.text_query or "").strip()
    return SearchCriteria(
        sectors=_coerce_sectors(output.sectors),
        exchanges=_coerce_exchanges(output.exchanges),
        price_earnings=_range(output.price_earnings_min, output.price_earnings_max),
        debt_to_equity=_range(output.debt_to_equity_min, output.debt_to_equity_max),
        return_on_equity_pct=_range(
            output.return_on_equity_min_pct, output.return_on_equity_max_pct
        ),
        revenue_growth_yoy_pct=_range(
            output.revenue_growth_min_pct, output.revenue_growth_max_pct
        ),
        market_cap_usd=_range(output.market_cap_min_usd, output.market_cap_max_usd),
        free_cash_flow_positive=output.free_cash_flow_positive,
        text_query=text or None,
    )


def _as_float(metric: MetricValue) -> float | None:
    if metric.value is None or metric.status != DataStatus.OK:
        return None
    return float(metric.value)


def _normalize_pct(value: float | None) -> float | None:
    """FMP devuelve márgenes y crecimientos como fracción (0.41) o como porcentaje (41) según el
    endpoint. Se normaliza a porcentaje para que "ROE mayor a 20" signifique lo mismo en los dos
    casos — sin esto, un ROE del 41% no pasaría un filtro de "> 20".
    """

    if value is None:
        return None
    return value * 100 if abs(value) <= 1 else value


class _Candidate:
    """Un símbolo del catálogo con sus ratios ya resueltos (o sin ellos)."""

    def __init__(self, ticker: Ticker, metrics: FinancialMetrics | None) -> None:
        self.symbol = ticker.symbol
        self.name = ticker.name
        self.exchange = ticker.exchange
        self.sector = normalize_sector(ticker.sector)
        self.price_earnings = (
            _as_float(metrics.price_earnings_ratio) if metrics else None
        )
        self.debt_to_equity = _as_float(metrics.debt_to_equity) if metrics else None
        self.return_on_equity_pct = (
            _normalize_pct(_as_float(metrics.return_on_equity_pct)) if metrics else None
        )
        self.revenue_growth_yoy_pct = (
            _normalize_pct(_as_float(metrics.revenue_growth_yoy_pct))
            if metrics
            else None
        )
        self.market_cap_usd = _as_float(metrics.market_cap) if metrics else None
        self.free_cash_flow = _as_float(metrics.free_cash_flow) if metrics else None


class TickerSearchService:
    """Ambos clientes son opcionales y cada ausencia degrada su propia etapa: sin Gemini no hay
    interpretación (se busca por texto), sin FMP no hay filtros numéricos (se declaran sin aplicar).
    El catálogo local es lo único imprescindible, y es dato propio.
    """

    def __init__(
        self,
        session_factory: async_sessionmaker[AsyncSession],
        *,
        gemini_client: GeminiClient | None = None,
        fmp_client: FMPClient | None = None,
        max_candidates: int = 60,
        max_metric_lookups: int = 12,
        system_prompt: str | None = None,
    ) -> None:
        self._session_factory = session_factory
        self._gemini = gemini_client
        self._fmp = fmp_client
        self._max_candidates = max_candidates
        self._max_metric_lookups = max_metric_lookups
        self._system_prompt = system_prompt or _load_system_prompt()

    async def search(self, query: str, *, limit: int = 20) -> NaturalSearchResponse:
        criteria, interpretation, source, reason = await self._interpret(query)

        # Sin criterios estructurados, la consulta cruda ES el criterio: buscar por texto es lo
        # único honesto que se puede hacer, y devolver vacío sería peor.
        if criteria.is_empty:
            criteria = SearchCriteria(text_query=query.strip())

        candidates = await self._load_candidates(criteria)
        metrics_available = self._fmp is not None
        unapplied: list[str] = []

        if criteria.requires_metrics and not metrics_available:
            unapplied = _describe_numeric_criteria(criteria)
            reason = _join_reasons(reason, _REASON_NO_METRICS)

        enriched = await self._with_metrics(candidates, criteria)
        matches = [
            match
            for candidate in enriched
            if (match := _match(candidate, criteria, metrics_available)) is not None
        ]

        return NaturalSearchResponse(
            query=query,
            interpretation=interpretation,
            criteria=criteria,
            criteria_source=source,
            results=matches[:limit],
            candidates_evaluated=len(candidates),
            ai_available=source == CriteriaSource.AI,
            metrics_available=metrics_available,
            unapplied_criteria=unapplied,
            degradation_reason=reason,
        )

    async def _interpret(
        self, query: str
    ) -> tuple[SearchCriteria, str | None, CriteriaSource, str | None]:
        """Devuelve `(criterios, interpretación, fuente, motivo_de_degradación)`. Nunca lanza: un
        fallo del modelo degrada a búsqueda por texto, no tumba el endpoint.
        """

        if (gemini := self._gemini) is None:
            return (
                SearchCriteria(),
                None,
                CriteriaSource.TEXT_FALLBACK,
                _REASON_NO_GEMINI,
            )

        result = await gemini.generate_structured_json(
            system_instruction=self._system_prompt,
            user_content=f"<consulta>{query}</consulta>",
            response_schema=_RESPONSE_SCHEMA,
        )

        if result.status != DataStatus.OK or result.raw_json_text is None:
            logger.warning("search_nl_gemini_call_failed")
            return (
                SearchCriteria(),
                None,
                CriteriaSource.TEXT_FALLBACK,
                _REASON_GEMINI_FAILED,
            )

        try:
            parsed = json.loads(result.raw_json_text)
            # strict=False solo en esta frontera JSON, mismo caso que el resto de los servicios que
            # consumen al modelo: JSON no tiene tipo nativo para Decimal ni Enum.
            output = _LLMSearchCriteria.model_validate(parsed, strict=False)
        except (json.JSONDecodeError, ValidationError) as exc:
            logger.warning("search_nl_output_invalid", extra={"error": str(exc)})
            return (
                SearchCriteria(),
                None,
                CriteriaSource.TEXT_FALLBACK,
                _REASON_GEMINI_INVALID,
            )

        criteria = build_criteria(output)
        interpretation = output.interpretation.strip() or None
        if criteria.is_empty:
            # El modelo respondió pero no reconoció ningún criterio ("hola", "qué hago con mi
            # plata"). Se degrada igual que un fallo: la búsqueda por texto es lo que queda.
            return (
                criteria,
                interpretation,
                CriteriaSource.TEXT_FALLBACK,
                _REASON_EMPTY_CRITERIA,
            )
        return criteria, interpretation, CriteriaSource.AI, None

    async def _load_candidates(self, criteria: SearchCriteria) -> list[Ticker]:
        """Filtra el catálogo por lo que se puede resolver en SQL: sector, bolsa y texto.

        El tope de candidatos se aplica en la query, no después: sin él, "tecnológicas" traería
        miles de filas a memoria para descartar casi todas.
        """

        filters: list[Any] = [Ticker.active.is_(True)]

        if criteria.exchanges:
            filters.append(Ticker.exchange.in_(criteria.exchanges))

        if criteria.sectors:
            # El catálogo guarda el sector CRUDO del proveedor (`Technology`), así que se traduce
            # el vocabulario del producto de vuelta al del proveedor. Comparación en minúsculas
            # porque el proveedor no garantiza capitalización.
            keys = [
                key
                for sector in criteria.sectors
                for key in provider_sector_keys(sector)
            ]
            if keys:
                filters.append(func.lower(Ticker.sector).in_(keys))
            else:
                # Un sector del producto sin equivalente en el proveedor (CRIPTO, SIN_CLASIFICAR)
                # no puede matchear ninguna fila del catálogo de acciones. Se corta acá en vez de
                # devolver el catálogo entero sin filtro de sector.
                return []

        if criteria.text_query:
            pattern = f"%{criteria.text_query}%"
            filters.append(
                or_(Ticker.symbol.ilike(pattern), Ticker.name.ilike(pattern))
            )

        async with self._session_factory() as session:
            rows = await session.scalars(
                select(Ticker)
                .where(*filters)
                .order_by(Ticker.symbol)
                .limit(self._max_candidates)
            )
            return list(rows.all())

    async def _with_metrics(
        self, candidates: list[Ticker], criteria: SearchCriteria
    ) -> list[_Candidate]:
        """Resuelve los ratios de los candidatos, solo si la consulta los necesita.

        Se consultan los primeros `max_metric_lookups`; el resto queda sin ratios y, como los
        criterios numéricos exigen un valor medido, no entra en los resultados. Es la decisión
        conservadora correcta: incluirlos sería afirmar que cumplen un filtro que nunca se les
        aplicó.
        """

        fmp = self._fmp
        if not criteria.requires_metrics or fmp is None:
            return [_Candidate(ticker, None) for ticker in candidates]

        selected = candidates[: self._max_metric_lookups]
        results = await asyncio.gather(
            *(fmp.get_financial_metrics(ticker.symbol) for ticker in selected),
            return_exceptions=True,
        )

        enriched: list[_Candidate] = []
        for ticker, result in zip(selected, results, strict=True):
            if isinstance(result, BaseException):
                logger.warning(
                    "search_nl_metrics_failed",
                    extra={"ticker": ticker.symbol, "error": str(result)},
                )
                enriched.append(_Candidate(ticker, None))
                continue
            enriched.append(_Candidate(ticker, result))
        return enriched


def _match(
    candidate: _Candidate, criteria: SearchCriteria, metrics_available: bool
) -> TickerMatch | None:
    """Decide si un candidato entra, y con qué razón.

    Cuando un criterio numérico está pedido pero el ratio no se pudo medir, el candidato queda
    AFUERA (con `metrics_available=True`). No se puede afirmar que cumple algo que no se midió, y
    colarlo convertiría la lista en "estos podrían cumplir", que no es lo que el usuario pidió.

    La excepción es el entorno sin proveedor de fundamentales (`metrics_available=False`): ahí no
    se descarta a nadie por los criterios numéricos —se los declara sin aplicar en la respuesta— o
    la búsqueda devolvería siempre cero resultados.
    """

    reasons: list[str] = []

    if criteria.sectors:
        if candidate.sector not in criteria.sectors:
            return None
        reasons.append(f"sector {sector_label(candidate.sector)}")

    if criteria.exchanges:
        if candidate.exchange not in criteria.exchanges:
            return None
        reasons.append(f"cotiza en {candidate.exchange.value}")

    if metrics_available:
        numeric_checks: list[tuple[NumericRange, float | None, str, str]] = [
            (criteria.price_earnings, candidate.price_earnings, "P/E", "x"),
            (criteria.debt_to_equity, candidate.debt_to_equity, "Deuda/Equity", "x"),
            (
                criteria.return_on_equity_pct,
                candidate.return_on_equity_pct,
                "ROE",
                "%",
            ),
            (
                criteria.revenue_growth_yoy_pct,
                candidate.revenue_growth_yoy_pct,
                "Crecimiento de ingresos",
                "%",
            ),
        ]
        for numeric_range, value, label, unit in numeric_checks:
            if numeric_range.is_empty:
                continue
            if value is None or not numeric_range.contains(value):
                return None
            reasons.append(f"{label} de {value:.2f}{unit}")

        if not criteria.market_cap_usd.is_empty:
            value = candidate.market_cap_usd
            if value is None or not criteria.market_cap_usd.contains(value):
                return None
            reasons.append(f"capitalización de {_compact_usd(value)}")

        if criteria.free_cash_flow_positive is not None:
            value = candidate.free_cash_flow
            if value is None or (value > 0) != criteria.free_cash_flow_positive:
                return None
            reasons.append(
                "flujo de caja libre positivo"
                if criteria.free_cash_flow_positive
                else "flujo de caja libre negativo"
            )

    if criteria.text_query and not reasons:
        # Búsqueda por texto pura: la razón es el match del texto, que si no quedaría vacía.
        reasons.append(f"coincide con «{criteria.text_query}»")

    return TickerMatch(
        symbol=candidate.symbol,
        name=candidate.name,
        exchange=candidate.exchange,
        sector=candidate.sector,
        sector_label=sector_label(candidate.sector),
        match_reason=_capitalize(", ".join(reasons))
        if reasons
        else "Coincide con la búsqueda",
        price_earnings=candidate.price_earnings,
        debt_to_equity=candidate.debt_to_equity,
        return_on_equity_pct=candidate.return_on_equity_pct,
        revenue_growth_yoy_pct=candidate.revenue_growth_yoy_pct,
        market_cap_usd=candidate.market_cap_usd,
    )


def _describe_numeric_criteria(criteria: SearchCriteria) -> list[str]:
    described = [
        numeric_range.describe(label)
        for label, numeric_range in criteria.numeric_fields
        if not numeric_range.is_empty
    ]
    if criteria.free_cash_flow_positive is not None:
        described.append(
            "Flujo de caja libre positivo"
            if criteria.free_cash_flow_positive
            else "Flujo de caja libre negativo"
        )
    return described


def _join_reasons(*reasons: str | None) -> str | None:
    present = [reason for reason in reasons if reason]
    return " ".join(present) if present else None


def _capitalize(text: str) -> str:
    return text[:1].upper() + text[1:] if text else text


def _compact_usd(value: float) -> str:
    """Montos en notación compacta: "USD 2,31 B" se lee de un vistazo y 2310000000000 no."""

    sign = "-" if value < 0 else ""
    absolute = abs(value)
    if absolute >= 1e12:
        return f"{sign}USD {absolute / 1e12:.2f} B"
    if absolute >= 1e9:
        return f"{sign}USD {absolute / 1e9:.2f} MM"
    if absolute >= 1e6:
        return f"{sign}USD {absolute / 1e6:.1f} M"
    return f"{sign}USD {absolute:.0f}"
