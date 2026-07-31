"""Cliente de ingesta para Polygon.io: precio y variación en tiempo real de Acciones y
Criptomonedas. Solo obtiene y parsea (.cursorrules §3) — la evaluación de umbrales de alerta
vive en el Nodo 1 de `processing/`, no aquí.
"""

from __future__ import annotations

from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from types import TracebackType
from typing import Any, Self

import httpx

from src.core.exceptions import (
    ProviderAuthenticationError,
    ProviderRateLimitError,
    ProviderResponseError,
    ProviderTimeoutError,
)
from src.ingestion.http_utils import request_with_retries
from src.ingestion.schemas_raw import MarketSnapshot
from src.validation.domain_models import AssetClass, DataStatus, MetricValue

_PROVIDER_NAME = "polygon.io"


def _to_decimal(raw: Any) -> Decimal | None:
    if raw is None:
        return None
    try:
        return Decimal(str(raw))
    except InvalidOperation:
        return None


def _metric(
    value: Decimal | None, *, status: DataStatus, source: str, as_of: datetime
) -> MetricValue:
    if value is None:
        return MetricValue(
            value=None, status=DataStatus.NO_DISPONIBLE, source=source, as_of=as_of
        )
    return MetricValue(value=value, status=status, source=source, as_of=as_of)


def _nested_dict(container: dict[Any, Any], key: str) -> dict[str, Any]:
    value = container.get(key)
    return value if isinstance(value, dict) else {}


class PolygonClient:
    def __init__(
        self,
        api_key: str,
        *,
        base_url: str = "https://api.polygon.io",
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

    async def get_equity_snapshot(self, ticker: str) -> MarketSnapshot:
        path = f"/v2/snapshot/locale/us/markets/stocks/tickers/{ticker}"
        return await self._get_snapshot(
            ticker, asset_class=AssetClass.EQUITY, path=path
        )

    async def get_crypto_snapshot(self, ticker: str) -> MarketSnapshot:
        normalized = (
            ticker
            if ticker.startswith("X:")
            else f"X:{ticker.replace('-', '').replace('/', '')}"
        )
        path = f"/v2/snapshot/locale/global/markets/crypto/tickers/{normalized}"
        return await self._get_snapshot(
            ticker, asset_class=AssetClass.CRYPTO, path=path
        )

    async def _get_snapshot(
        self, ticker: str, *, asset_class: AssetClass, path: str
    ) -> MarketSnapshot:
        fetched_at = datetime.now(timezone.utc)
        source = f"{_PROVIDER_NAME}{path}"

        try:
            response = await request_with_retries(
                self._client,
                "GET",
                path,
                provider=_PROVIDER_NAME,
                max_attempts=self._max_retry_attempts,
                params={"apiKey": self._api_key},
            )
        except (
            ProviderTimeoutError,
            ProviderRateLimitError,
            ProviderAuthenticationError,
            ProviderResponseError,
        ):
            return self._empty_snapshot(
                ticker, asset_class, fetched_at, source, status=DataStatus.ERROR_API
            )

        if response.status_code == 404:
            return self._empty_snapshot(
                ticker, asset_class, fetched_at, source, status=DataStatus.NO_DISPONIBLE
            )

        try:
            payload = response.json()
        except ValueError:
            return self._empty_snapshot(
                ticker, asset_class, fetched_at, source, status=DataStatus.ERROR_API
            )

        ticker_data = payload.get("ticker") if isinstance(payload, dict) else None
        if not isinstance(ticker_data, dict):
            return self._empty_snapshot(
                ticker, asset_class, fetched_at, source, status=DataStatus.NO_DISPONIBLE
            )

        day = _nested_dict(ticker_data, "day")
        prev_day = _nested_dict(ticker_data, "prevDay")

        return MarketSnapshot(
            ticker=ticker,
            asset_class=asset_class,
            fetched_at=fetched_at,
            last_price=_metric(
                _to_decimal(day.get("c")),
                status=DataStatus.OK,
                source=source,
                as_of=fetched_at,
            ),
            day_open=_metric(
                _to_decimal(day.get("o")),
                status=DataStatus.OK,
                source=source,
                as_of=fetched_at,
            ),
            day_high=_metric(
                _to_decimal(day.get("h")),
                status=DataStatus.OK,
                source=source,
                as_of=fetched_at,
            ),
            day_low=_metric(
                _to_decimal(day.get("l")),
                status=DataStatus.OK,
                source=source,
                as_of=fetched_at,
            ),
            prev_close=_metric(
                _to_decimal(prev_day.get("c")),
                status=DataStatus.OK,
                source=source,
                as_of=fetched_at,
            ),
            volume=_metric(
                _to_decimal(day.get("v")),
                status=DataStatus.OK,
                source=source,
                as_of=fetched_at,
            ),
            day_change_pct=_metric(
                _to_decimal(ticker_data.get("todaysChangePerc")),
                status=DataStatus.OK,
                source=source,
                as_of=fetched_at,
            ),
        )

    def _empty_snapshot(
        self,
        ticker: str,
        asset_class: AssetClass,
        fetched_at: datetime,
        source: str,
        *,
        status: DataStatus,
    ) -> MarketSnapshot:
        empty = MetricValue(value=None, status=status, source=source, as_of=fetched_at)
        return MarketSnapshot(
            ticker=ticker,
            asset_class=asset_class,
            fetched_at=fetched_at,
            last_price=empty,
            day_open=empty,
            day_high=empty,
            day_low=empty,
            prev_close=empty,
            volume=empty,
            day_change_pct=empty,
        )
