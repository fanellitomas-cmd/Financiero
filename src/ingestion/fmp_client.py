"""Cliente de ingesta para Financial Modeling Prep: fundamentales, ratios y filings SEC.

NOTA DE VERIFICACIÓN — leer antes de usar en producción: el entorno de desarrollo no tuvo
acceso de red a financialmodelingprep.com para confirmar en vivo los nombres exactos de campo
de cada endpoint (varían entre la API legacy `/api/v3` y la API `stable`, y entre planes). Los
alias en `_*_KEYS` reflejan los nombres públicamente documentados con mayor confianza, pero
DEBEN validarse contra una respuesta real antes de confiar en este cliente para producción.
Si un alias no matchea, el campo queda `NO_DISPONIBLE` — nunca se inventa un valor (regla de
cero alucinación de .cursorrules §1), así que un alias desactualizado degrada el dato en vez
de corromperlo.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import date, datetime, timezone
from decimal import Decimal, InvalidOperation
from types import TracebackType
from typing import Any, Literal, Self

import httpx

from src.core.exceptions import (
    ProviderAuthenticationError,
    ProviderRateLimitError,
    ProviderResponseError,
    ProviderTimeoutError,
)
from src.core.http_utils import request_with_retries
from src.ingestion.schemas_raw import (
    CompanyProfile,
    FilingReference,
    FinancialStatements,
)
from src.validation.domain_models import DataStatus, FinancialMetrics, MetricValue

logger = logging.getLogger(__name__)

_PROVIDER_NAME = "financialmodelingprep.com"

_PE_RATIO_KEYS = ("priceToEarningsRatio", "peRatioTTM", "peRatio")
_PEG_RATIO_KEYS = ("pegRatio", "pegRatioTTM")
_DEBT_TO_EBITDA_KEYS = (
    "netDebtToEBITDA",
    "netDebtToEBITDATTM",
    "debtToEbitda",
    "debtToEBITDATTM",
)
_DEBT_TO_EQUITY_KEYS = (
    "debtToEquityRatio",
    "debtToEquityRatioTTM",
    "debtEquityRatio",
    "debtEquityRatioTTM",
)
_CURRENT_RATIO_KEYS = ("currentRatio", "currentRatioTTM")
_GROSS_MARGIN_KEYS = ("grossProfitMargin", "grossProfitMarginTTM")
_OPERATING_MARGIN_KEYS = ("operatingProfitMargin", "operatingProfitMarginTTM")
_ROE_KEYS = ("returnOnEquity", "returnOnEquityTTM", "roe")
_FCF_YIELD_KEYS = ("freeCashFlowYield", "freeCashFlowYieldTTM")
_REVENUE_GROWTH_KEYS = ("revenueGrowth", "growthRevenue")
_MARKET_CAP_KEYS = ("marketCap", "mktCap")
_SHARES_OUTSTANDING_KEYS = (
    "sharesOutstanding",
    "outstandingShares",
    "weightedAverageShsOut",
)
_FREE_CASH_FLOW_KEYS = ("freeCashFlow",)
_REPORT_DATE_KEYS = ("date", "fiscalDateEnding")
_SECTOR_KEYS = ("sector",)
_INDUSTRY_KEYS = ("industry",)
_COMPANY_NAME_KEYS = ("companyName", "name")


def _first_present(payload: dict[str, Any], keys: tuple[str, ...]) -> Any:
    for key in keys:
        if key in payload and payload[key] is not None:
            return payload[key]
    return None


def _statement_rows(payload: Any) -> list[dict[str, Any]]:
    """Las filas de un estado contable. Lo que no sea una lista de objetos vuelve vacío: un payload
    con otra forma es un endpoint que no respondió lo esperado, y propagarlo obligaría a cada
    consumidor a revalidar el tipo.
    """

    if not isinstance(payload, list):
        return []
    return [row for row in payload if isinstance(row, dict)]


def _first_object(payload: Any) -> dict[str, Any] | None:
    if isinstance(payload, list) and payload and isinstance(payload[0], dict):
        return payload[0]
    if isinstance(payload, dict):
        return payload
    return None


def _str_or_none(raw: Any) -> str | None:
    """Texto del proveedor, o `None` si no es un string usable. Un `""` se trata como ausente: un
    sector vacío no es un sector.
    """

    if not isinstance(raw, str):
        return None
    stripped = raw.strip()
    return stripped or None


def _to_decimal(raw: Any) -> Decimal | None:
    if raw is None:
        return None
    try:
        return Decimal(str(raw))
    except InvalidOperation:
        return None


def _parse_datetime(raw: Any) -> datetime | None:
    if not isinstance(raw, str) or not raw:
        return None
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d"):
        try:
            return datetime.strptime(raw, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    # ISO-8601 con `T` y zona: no es el formato que FMP usa hoy, pero un reporte sin fecha se
    # muestra como "sin fecha" en la biblioteca del Corporate Hub, y eso es un dato perdido por un
    # detalle de formato. `fromisoformat` acepta la `Z` desde 3.11.
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=timezone.utc)


_MetricCandidate = tuple[dict[str, Any] | None, DataStatus, tuple[str, ...], str]


def _resolve_metric(
    candidates: list[_MetricCandidate], *, as_of: datetime
) -> MetricValue:
    """Prueba cada candidato (payload, status_del_endpoint, alias_de_claves, source) en orden
    y usa el primero con un valor numérico real. Si ningún candidato tiene el dato pero al
    menos un endpoint respondió, el resultado es NO_DISPONIBLE; si todos los endpoints
    candidatos fallaron, es ERROR_API (distinción clave: "no lo tienen" vs. "no pudimos preguntar").
    """

    any_endpoint_ok = False
    for payload, status, keys, source in candidates:
        any_endpoint_ok = any_endpoint_ok or status == DataStatus.OK
        if payload is None:
            continue
        decimal_value = _to_decimal(_first_present(payload, keys))
        if decimal_value is not None:
            return MetricValue(
                value=decimal_value, status=DataStatus.OK, source=source, as_of=as_of
            )

    fallback_source = candidates[0][3] if candidates else _PROVIDER_NAME
    fallback_status = (
        DataStatus.NO_DISPONIBLE if any_endpoint_ok else DataStatus.ERROR_API
    )
    return MetricValue(
        value=None, status=fallback_status, source=fallback_source, as_of=as_of
    )


class FMPClient:
    def __init__(
        self,
        api_key: str,
        *,
        base_url: str = "https://financialmodelingprep.com/stable",
        timeout_seconds: float = 15.0,
        max_retry_attempts: int = 3,
        http_client: httpx.AsyncClient | None = None,
    ) -> None:
        self._api_key = api_key
        self._max_retry_attempts = max_retry_attempts
        self._owns_client = http_client is None
        self._client = http_client or httpx.AsyncClient(
            base_url=base_url, timeout=httpx.Timeout(timeout_seconds)
        )

    async def aclose(self) -> None:
        if self._owns_client:
            await self._client.aclose()

    async def __aenter__(self) -> Self:
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        await self.aclose()

    async def _fetch_json(
        self, path: str, params: dict[str, Any]
    ) -> tuple[Any, DataStatus]:
        try:
            response = await request_with_retries(
                self._client,
                "GET",
                path,
                provider=_PROVIDER_NAME,
                max_attempts=self._max_retry_attempts,
                params={**params, "apikey": self._api_key},
            )
        except (
            ProviderTimeoutError,
            ProviderRateLimitError,
            ProviderAuthenticationError,
            ProviderResponseError,
        ) as exc:
            logger.warning(
                "fmp_endpoint_failed", extra={"path": path, "error": str(exc)}
            )
            return None, DataStatus.ERROR_API

        if response.status_code == 404:
            return None, DataStatus.NO_DISPONIBLE

        try:
            return response.json(), DataStatus.OK
        except ValueError:
            return None, DataStatus.ERROR_API

    async def get_financial_metrics(self, ticker: str) -> FinancialMetrics:
        fetched_at = datetime.now(timezone.utc)

        (
            (ratios_payload, ratios_status),
            (key_metrics_payload, key_metrics_status),
            (growth_payload, growth_status),
            (profile_payload, profile_status),
            (cash_flow_payload, cash_flow_status),
        ) = await asyncio.gather(
            self._fetch_json("/ratios-ttm", {"symbol": ticker}),
            self._fetch_json("/key-metrics-ttm", {"symbol": ticker}),
            self._fetch_json("/financial-growth", {"symbol": ticker, "limit": 1}),
            self._fetch_json("/profile", {"symbol": ticker}),
            self._fetch_json(
                "/cash-flow-statement",
                {"symbol": ticker, "period": "quarter", "limit": 1},
            ),
        )

        ratios = _first_object(ratios_payload)
        key_metrics = _first_object(key_metrics_payload)
        growth = _first_object(growth_payload)
        profile = _first_object(profile_payload)
        cash_flow = _first_object(cash_flow_payload)

        ratios_source = f"{_PROVIDER_NAME}/ratios-ttm"
        key_metrics_source = f"{_PROVIDER_NAME}/key-metrics-ttm"
        growth_source = f"{_PROVIDER_NAME}/financial-growth"
        profile_source = f"{_PROVIDER_NAME}/profile"
        cash_flow_source = f"{_PROVIDER_NAME}/cash-flow-statement"

        return FinancialMetrics(
            ticker=ticker,
            fetched_at=fetched_at,
            price_earnings_ratio=_resolve_metric(
                [(ratios, ratios_status, _PE_RATIO_KEYS, ratios_source)],
                as_of=fetched_at,
            ),
            price_earnings_growth_ratio=_resolve_metric(
                [
                    (ratios, ratios_status, _PEG_RATIO_KEYS, ratios_source),
                    (
                        key_metrics,
                        key_metrics_status,
                        _PEG_RATIO_KEYS,
                        key_metrics_source,
                    ),
                ],
                as_of=fetched_at,
            ),
            debt_to_ebitda=_resolve_metric(
                [
                    (
                        key_metrics,
                        key_metrics_status,
                        _DEBT_TO_EBITDA_KEYS,
                        key_metrics_source,
                    )
                ],
                as_of=fetched_at,
            ),
            debt_to_equity=_resolve_metric(
                [
                    (ratios, ratios_status, _DEBT_TO_EQUITY_KEYS, ratios_source),
                    (
                        key_metrics,
                        key_metrics_status,
                        _DEBT_TO_EQUITY_KEYS,
                        key_metrics_source,
                    ),
                ],
                as_of=fetched_at,
            ),
            free_cash_flow=_resolve_metric(
                [(cash_flow, cash_flow_status, _FREE_CASH_FLOW_KEYS, cash_flow_source)],
                as_of=fetched_at,
            ),
            free_cash_flow_yield_pct=_resolve_metric(
                [
                    (
                        key_metrics,
                        key_metrics_status,
                        _FCF_YIELD_KEYS,
                        key_metrics_source,
                    )
                ],
                as_of=fetched_at,
            ),
            revenue_growth_yoy_pct=_resolve_metric(
                [(growth, growth_status, _REVENUE_GROWTH_KEYS, growth_source)],
                as_of=fetched_at,
            ),
            gross_margin_pct=_resolve_metric(
                [(ratios, ratios_status, _GROSS_MARGIN_KEYS, ratios_source)],
                as_of=fetched_at,
            ),
            operating_margin_pct=_resolve_metric(
                [(ratios, ratios_status, _OPERATING_MARGIN_KEYS, ratios_source)],
                as_of=fetched_at,
            ),
            return_on_equity_pct=_resolve_metric(
                [
                    (ratios, ratios_status, _ROE_KEYS, ratios_source),
                    (key_metrics, key_metrics_status, _ROE_KEYS, key_metrics_source),
                ],
                as_of=fetched_at,
            ),
            current_ratio=_resolve_metric(
                [(ratios, ratios_status, _CURRENT_RATIO_KEYS, ratios_source)],
                as_of=fetched_at,
            ),
            shares_outstanding=_resolve_metric(
                [(profile, profile_status, _SHARES_OUTSTANDING_KEYS, profile_source)],
                as_of=fetched_at,
            ),
            market_cap=_resolve_metric(
                [(profile, profile_status, _MARKET_CAP_KEYS, profile_source)],
                as_of=fetched_at,
            ),
            fundamentals_period="TTM",
            fundamentals_report_date=_parse_datetime(
                _first_present(cash_flow, _REPORT_DATE_KEYS) if cash_flow else None
            ),
        )

    async def get_company_profile(self, ticker: str) -> CompanyProfile | None:
        """Perfil de la empresa (`/profile`): sector, industria y nombre.

        Devuelve `None` si el proveedor falló o no conoce el símbolo, en vez de un perfil con todos
        los campos vacíos: quien lo consume necesita distinguir "no lo pudimos preguntar" de "la
        empresa no tiene sector asignado", y un objeto lleno de `None` no permite esa distinción.
        Un perfil que SÍ llegó pero sin sector devuelve el objeto con `sector=None`.
        """

        payload, status = await self._fetch_json("/profile", {"symbol": ticker})
        if status != DataStatus.OK:
            return None

        profile = _first_object(payload)
        if profile is None:
            return None

        return CompanyProfile(
            ticker=ticker,
            company_name=_str_or_none(_first_present(profile, _COMPANY_NAME_KEYS)),
            sector=_str_or_none(_first_present(profile, _SECTOR_KEYS)),
            industry=_str_or_none(_first_present(profile, _INDUSTRY_KEYS)),
        )

    async def list_recent_filings(
        self, ticker: str, filing_type: str | None = None, *, limit: int = 4
    ) -> list[FilingReference]:
        """Filings del símbolo, sin distinguir "no hay" de "el proveedor falló".

        Sirve para los llamadores que solo enriquecen un dossier con lo que haya: si el proveedor no
        contesta, el dossier va sin filings y sigue. Quien tenga que MOSTRAR la diferencia (el
        Corporate Hub la muestra) usa `list_recent_filings_with_status`.
        """

        filings, _ = await self.list_recent_filings_with_status(
            ticker, filing_type, limit=limit
        )
        return filings

    async def list_recent_filings_with_status(
        self, ticker: str, filing_type: str | None = None, *, limit: int = 4
    ) -> tuple[list[FilingReference], DataStatus]:
        """Ídem, con el estado de la llamada. `filing_type=None` trae todos los tipos.

        El parámetro pasó de `Literal["10-K","10-Q"]` a `str | None` cuando el Corporate Hub
        necesitó los 8-K y la lista mezclada: restringirlo obligaba a una llamada por tipo para
        armar una biblioteca que el proveedor devuelve de una.
        """

        payload, status = await self._fetch_json(
            "/sec-filings-search/symbol",
            {
                "symbol": ticker,
                **({"type": filing_type} if filing_type else {}),
                "limit": limit,
            },
        )
        if status != DataStatus.OK or not isinstance(payload, list):
            return [], status if status != DataStatus.OK else DataStatus.ERROR_API

        filings: list[FilingReference] = []
        for entry in payload:
            if not isinstance(entry, dict):
                continue
            filings.append(
                FilingReference(
                    ticker=ticker,
                    # El tipo que informa el proveedor, no el que se pidió: al pedir "todos", cada
                    # fila trae el suyo, y forzar el del parámetro etiquetaría un 8-K como 10-K.
                    filing_type=_str_or_none(
                        _first_present(entry, ("type", "formType"))
                    )
                    or filing_type
                    or "OTHER",
                    filed_at=_parse_datetime(
                        _first_present(entry, ("filingDate", "fillingDate"))
                    ),
                    accepted_at=_parse_datetime(
                        _first_present(entry, ("acceptedDate",))
                    ),
                    filing_url=_first_present(entry, ("link", "filingUrl")),
                    final_document_url=_first_present(
                        entry, ("finalLink", "finalDocumentUrl")
                    ),
                )
            )
        return filings, DataStatus.OK

    async def get_earnings_calendar(
        self, from_date: date, to_date: date
    ) -> tuple[list[dict[str, Any]], DataStatus]:
        """Balances programados y publicados en un rango.

        Devuelve las filas CRUDAS del proveedor junto con el estado, en vez de un modelo de dominio:
        la normalización (sesión, sorpresas, período) vive en `CorporateService`, que es quien tiene
        las reglas del producto. Este cliente solo sabe hablar con FMP.

        El `DataStatus` viaja aparte de la lista justamente para que el llamador pueda distinguir
        "el rango no tiene balances" de "el proveedor falló" — dos listas vacías con significados
        opuestos.
        """

        payload, status = await self._fetch_json(
            "/earnings-calendar",
            {"from": from_date.isoformat(), "to": to_date.isoformat()},
        )
        if status != DataStatus.OK or not isinstance(payload, list):
            return [], status if status != DataStatus.OK else DataStatus.ERROR_API
        return [entry for entry in payload if isinstance(entry, dict)], DataStatus.OK

    async def get_earnings_history(
        self, ticker: str, *, limit: int = 8
    ) -> tuple[list[dict[str, Any]], DataStatus]:
        """Trimestres reportados de un símbolo, crudos, para el histórico de sorpresas."""

        payload, status = await self._fetch_json(
            "/earnings", {"symbol": ticker, "limit": limit}
        )
        if status != DataStatus.OK or not isinstance(payload, list):
            return [], status if status != DataStatus.OK else DataStatus.ERROR_API
        return [entry for entry in payload if isinstance(entry, dict)], DataStatus.OK

    async def get_financial_statements(
        self,
        ticker: str,
        *,
        period: Literal["annual", "quarter"] = "annual",
        limit: int = 5,
    ) -> tuple[FinancialStatements, DataStatus]:
        """Los tres estados contables del símbolo, crudos y en paralelo.

        Devuelve las filas TAL COMO las manda el proveedor: los cálculos (márgenes, DuPont, flags)
        viven en `AiLabService`, que es quien tiene los umbrales del producto. Este cliente solo sabe
        hablar con FMP.

        El estado agregado es **OK si al menos uno de los tres estados llegó**: un balance general
        disponible sin flujo de caja sigue permitiendo la mitad del análisis, y devolver ERROR_API
        entero por eso escondería datos que sí están. Cada lista vacía se declara igual del lado del
        servicio.
        """

        params = {"symbol": ticker, "period": period, "limit": limit}
        (
            (income_payload, income_status),
            (balance_payload, balance_status),
            (cash_payload, cash_status),
        ) = await asyncio.gather(
            self._fetch_json("/income-statement", params),
            self._fetch_json("/balance-sheet-statement", params),
            self._fetch_json("/cash-flow-statement", params),
        )

        statements = FinancialStatements(
            ticker=ticker,
            period=period,
            income=_statement_rows(income_payload),
            balance=_statement_rows(balance_payload),
            cash_flow=_statement_rows(cash_payload),
        )

        any_ok = any(
            status == DataStatus.OK
            for status in (income_status, balance_status, cash_status)
        )
        if not any_ok:
            # Se elige el estado del estado de resultados como representativo: es el que decide si el
            # análisis puede existir, y devolver tres estados distintos obligaría al llamador a
            # reimplementar esta misma decisión.
            return statements, income_status
        return statements, DataStatus.OK
