"""Cliente de ingesta para Polygon.io: precio y variación en tiempo real de Acciones y
Criptomonedas, más el catálogo de referencia de tickers. Solo obtiene y parsea
(.cursorrules §3) — la evaluación de umbrales de alerta vive en el Nodo 1 de `processing/`,
no aquí.

NOTA DE VERIFICACIÓN — `list_stock_tickers` (`/v3/reference/tickers`): el entorno de
desarrollo no tuvo acceso de red a api.polygon.io (bloqueado por política de egress), así que
el contrato exacto NO se verificó en vivo. Se implementó contra la documentación pública.
Puntos concretos a confirmar contra una llamada real antes de producción:
  - `primary_exchange` viene como código MIC ISO 10383 (`XNAS` para Nasdaq, `XNYS` para NYSE),
    NO como el string "NASDAQ"/"NYSE". De esto depende el mapeo en
    `app/services/ticker_catalog_service.py::normalize_exchange` — si el proveedor devolviera
    los nombres largos, ese mapeo hay que ampliarlo (hoy caería todo en `OTHER`, que es
    visible y auditable, no un fallo silencioso).
  - La paginación usa el cursor `next_url` en el cuerpo de la respuesta, y ese URL NO incluye
    la apiKey — hay que reinyectarla en cada salto (se hace acá).
Si el contrato real difiere, esto degrada a "ninguna página" o lanza `ProviderResponseError`;
nunca inventa entradas de catálogo.

Lo mismo aplica a `get_market_movers`
(`/v2/snapshot/locale/us/markets/stocks/{gainers|losers}`), implementado contra la doc pública
sin poder verificarlo en vivo. A confirmar antes de producción:
  - La lista viene en la clave `tickers`, cada entrada con `ticker`, `todaysChangePerc` y el
    precio de cierre del día en `day.c` (misma forma que el snapshot por ticker).
  - El endpoint cubre el universo de acciones de US y NO dice en qué bolsa cotiza cada símbolo;
    el filtro NASDAQ/NYSE se resuelve cruzando contra el catálogo local
    (`app/services/market_summary_service.py`).
Si el contrato difiere, esto degrada a lista vacía con log — el resumen de mercado dirá que no
hay datos de movers, nunca inventará un ticker ni un porcentaje.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from enum import Enum
from types import TracebackType
from typing import Any, Self

import httpx

from src.core.exceptions import (
    ProviderAuthenticationError,
    ProviderRateLimitError,
    ProviderResponseError,
    ProviderTimeoutError,
)
from src.core.http_utils import request_with_retries
from src.ingestion.schemas_raw import MarketMover, MarketSnapshot, ReferenceTicker
from src.validation.domain_models import AssetClass, DataStatus, MetricValue

logger = logging.getLogger(__name__)

_PROVIDER_NAME = "polygon.io"

# Tope de páginas por corrida de sincronización. Polygon devuelve ~10k tickers de acciones en
# páginas de 1000, así que 50 deja margen de sobra; existe solo para que un `next_url` que se
# auto-referencie (bug del proveedor) no deje el loop girando para siempre.
_MAX_TICKER_PAGES = 50


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


def _optional_str(raw: Any) -> str | None:
    return raw if isinstance(raw, str) and raw else None


def _parse_reference_ticker(entry: Any) -> ReferenceTicker | None:
    """Devuelve `None` (en vez de lanzar) si la entrada no tiene lo mínimo indispensable
    (`ticker` y `name`): el llamador la descarta y sigue con el resto de la página.
    """

    if not isinstance(entry, dict):
        return None

    symbol = _optional_str(entry.get("ticker"))
    name = _optional_str(entry.get("name"))
    if symbol is None or name is None:
        logger.warning(
            "polygon_reference_ticker_incomplete", extra={"entry": str(entry)[:120]}
        )
        return None

    raw_active = entry.get("active")
    return ReferenceTicker(
        symbol=symbol,
        name=name,
        primary_exchange=_optional_str(entry.get("primary_exchange")),
        asset_type=_optional_str(entry.get("type")),
        # Si el proveedor omite `active`, se asume activo: el pedido ya fue `active=true`, así
        # que su ausencia es un hueco del payload, no una señal de que esté delistado.
        active=raw_active if isinstance(raw_active, bool) else True,
    )


class MoverDirection(str, Enum):
    """Las dos direcciones que acepta el endpoint de movers de Polygon. Enum y no string suelto
    para que un typo (`"gainer"`) sea un error de tipos y no un 404 en runtime.
    """

    GAINERS = "gainers"
    LOSERS = "losers"


def _parse_market_mover(
    entry: Any, *, source: str, fetched_at: datetime
) -> MarketMover | None:
    """Parsea una entrada de movers, o `None` si no tiene ticker — sin símbolo la entrada es
    inútil, y descartarla es preferible a inventarle uno.
    """

    if not isinstance(entry, dict):
        return None
    ticker = _optional_str(entry.get("ticker"))
    if not ticker:
        return None

    day = _nested_dict(entry, "day")
    return MarketMover(
        ticker=ticker,
        last_price=_metric(
            _to_decimal(day.get("c")),
            status=DataStatus.OK,
            source=source,
            as_of=fetched_at,
        ),
        day_change_pct=_metric(
            _to_decimal(entry.get("todaysChangePerc")),
            status=DataStatus.OK,
            source=source,
            as_of=fetched_at,
        ),
    )


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

    async def list_stock_tickers(
        self, *, page_size: int = 1000, active: bool = True
    ) -> AsyncIterator[list[ReferenceTicker]]:
        """Recorre `/v3/reference/tickers?market=stocks` siguiendo el cursor `next_url` y
        devuelve una PÁGINA por iteración (no un ticker por iteración) para que el llamador
        pueda persistir y commitear por lote — son ~10k símbolos, hacerlo de a uno sería
        innecesariamente lento.

        Una entrada malformada se descarta con log y no aborta la corrida: un símbolo raro no
        debe invalidar la sincronización de los otros 9999.
        """

        params: dict[str, Any] | None = {
            "market": "stocks",
            "active": str(active).lower(),
            "limit": page_size,
            "apiKey": self._api_key,
        }
        url: str | None = "/v3/reference/tickers"
        pages_seen = 0

        while url is not None and pages_seen < _MAX_TICKER_PAGES:
            response = await request_with_retries(
                self._client,
                "GET",
                url,
                provider=_PROVIDER_NAME,
                max_attempts=self._max_retry_attempts,
                # `params=None` es equivalente a no mandarlo: httpx deja el querystring del
                # URL intacto, que es justo lo que hace falta al seguir un `next_url`.
                params=params,
            )
            if response.status_code != 200:
                raise ProviderResponseError(
                    f"{_PROVIDER_NAME} devolvió {response.status_code} en {url}."
                )

            try:
                payload = response.json()
            except ValueError as exc:
                raise ProviderResponseError(
                    f"{_PROVIDER_NAME} devolvió un cuerpo no-JSON en {url}."
                ) from exc

            if not isinstance(payload, dict):
                raise ProviderResponseError(
                    f"{_PROVIDER_NAME} devolvió un cuerpo inesperado en {url}."
                )

            raw_results = payload.get("results")
            page = (
                [
                    parsed
                    for entry in raw_results
                    if (parsed := _parse_reference_ticker(entry)) is not None
                ]
                if isinstance(raw_results, list)
                else []
            )
            if page:
                yield page

            pages_seen += 1
            next_url = payload.get("next_url")
            if isinstance(next_url, str) and next_url:
                # `next_url` ya trae market/active/limit/cursor embebidos; solo le falta la
                # credencial. Se mergea DENTRO del URL en vez de pasarla por `params`: httpx
                # REEMPLAZA el querystring del URL cuando recibe `params`, así que hacerlo por
                # ahí borraría el cursor y cada request volvería a traer la primera página
                # (loop infinito hasta el tope de `_MAX_TICKER_PAGES`).
                url = str(
                    httpx.URL(next_url).copy_merge_params({"apiKey": self._api_key})
                )
                params = None
            else:
                url = None

        if pages_seen >= _MAX_TICKER_PAGES and url is not None:
            logger.warning(
                "polygon_ticker_pagination_cap_reached",
                extra={"pages_seen": pages_seen},
            )

    async def get_market_movers(self, direction: MoverDirection) -> list[MarketMover]:
        """Los tickers que más subieron (`gainers`) o bajaron (`losers`) en la jornada, según
        `/v2/snapshot/locale/us/markets/stocks/{direction}`.

        Devuelve lista vacía ante cualquier fallo de proveedor o payload inesperado, en vez de
        lanzar: el resumen de mercado que la consume tiene que poder decir "no hay datos de
        alzas ahora" y seguir sirviendo el resto (.cursorrules §2). Un fallo acá se registra
        explícito, no se traga en silencio.
        """

        path = f"/v2/snapshot/locale/us/markets/stocks/{direction.value}"
        source = f"{_PROVIDER_NAME}{path}"
        fetched_at = datetime.now(timezone.utc)

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
        ) as exc:
            logger.warning(
                "polygon_market_movers_failed",
                extra={"direction": direction.value, "error": str(exc)},
            )
            return []

        try:
            payload = response.json()
        except ValueError:
            logger.warning(
                "polygon_market_movers_invalid_json",
                extra={"direction": direction.value},
            )
            return []

        raw_tickers = payload.get("tickers") if isinstance(payload, dict) else None
        if not isinstance(raw_tickers, list):
            logger.warning(
                "polygon_market_movers_unexpected_payload",
                extra={"direction": direction.value},
            )
            return []

        movers: list[MarketMover] = []
        for entry in raw_tickers:
            mover = _parse_market_mover(entry, source=source, fetched_at=fetched_at)
            if mover is not None:
                movers.append(mover)
        return movers

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
