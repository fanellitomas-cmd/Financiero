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
from datetime import datetime, timezone
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
from src.ingestion.schemas_raw import FilingReference
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


def _first_present(payload: dict[str, Any], keys: tuple[str, ...]) -> Any:
    for key in keys:
        if key in payload and payload[key] is not None:
            return payload[key]
    return None


def _first_object(payload: Any) -> dict[str, Any] | None:
    if isinstance(payload, list) and payload and isinstance(payload[0], dict):
        return payload[0]
    if isinstance(payload, dict):
        return payload
    return None


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
    return None


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

    async def list_recent_filings(
        self, ticker: str, filing_type: Literal["10-K", "10-Q"], *, limit: int = 4
    ) -> list[FilingReference]:
        payload, status = await self._fetch_json(
            "/sec-filings-search/symbol",
            {"symbol": ticker, "type": filing_type, "limit": limit},
        )
        if status != DataStatus.OK or not isinstance(payload, list):
            return []

        filings: list[FilingReference] = []
        for entry in payload:
            if not isinstance(entry, dict):
                continue
            filings.append(
                FilingReference(
                    ticker=ticker,
                    filing_type=filing_type,
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
        return filings
