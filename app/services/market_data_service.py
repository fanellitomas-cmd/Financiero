"""Servicio de datos de mercado que consume la app, sobre el mismo `PolygonClient` que usa el
Nodo 1 del motor (reutilizado, no uno nuevo):

  - `get_quotes` — precio y % de variación del día por ticker, para el Heatmap del Dashboard. No
    pasa por la detección de alertas del Nodo 1 (que solo devuelve algo si se cruza un umbral):
    el Heatmap necesita el dato siempre, haya o no alerta.
  - `get_history` — velas diarias OHLC para el chart de la Ficha.

Las dos degradan sin lanzar: `get_quotes` tile-por-tile (un proveedor caído para UN ticker no
tumba el heatmap entero) y `get_history` con `bars` vacío más un motivo legible.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import date

from app.models.enums import AssetType
from app.schemas.market import OhlcBarOut, TickerHistory, TickerQuote
from src.ingestion.polygon_client import PolygonClient
from src.validation.domain_models import DataStatus

logger = logging.getLogger(__name__)

_REASON_NO_BARS = (
    "No hay velas históricas para este rango (el proveedor no devolvió datos: puede ser un "
    "rango sin ruedas, un ticker sin histórico, o falta POLYGON_API_KEY en .env)."
)
_REASON_PROVIDER_FAILED = "No se pudo obtener el histórico de precios en este momento."


class MarketDataService:
    def __init__(self, polygon_client: PolygonClient) -> None:
        self._polygon_client = polygon_client

    async def get_quotes(self, items: list[tuple[str, AssetType]]) -> list[TickerQuote]:
        return list(
            await asyncio.gather(
                *(self._get_quote(ticker, asset_type) for ticker, asset_type in items)
            )
        )

    async def _get_quote(self, ticker: str, asset_type: AssetType) -> TickerQuote:
        try:
            snapshot = (
                await self._polygon_client.get_equity_snapshot(ticker)
                if asset_type == AssetType.STOCK
                else await self._polygon_client.get_crypto_snapshot(ticker)
            )
        except Exception as exc:  # noqa: BLE001 — un proveedor caído para UN ticker no debe
            # tumbar el heatmap entero: se degrada ese tile a "sin dato" y se registra
            # explícitamente (.cursorrules §2). `PolygonClient` ya degrada sus propios
            # errores de proveedor a `DataStatus.ERROR_API` sin lanzar — esto es una red de
            # seguridad extra ante un bug inesperado, no el camino esperado.
            logger.warning(
                "market_data_quote_failed", extra={"ticker": ticker, "error": str(exc)}
            )
            return TickerQuote(
                ticker=ticker,
                last_price=None,
                day_change_pct=None,
                status=DataStatus.ERROR_API,
            )

        return TickerQuote(
            ticker=ticker,
            last_price=float(snapshot.last_price.value)
            if snapshot.last_price.value is not None
            else None,
            day_change_pct=float(snapshot.day_change_pct.value)
            if snapshot.day_change_pct.value is not None
            else None,
            status=snapshot.last_price.status,
        )

    async def get_history(
        self, ticker: str, *, start: date, end: date
    ) -> TickerHistory:
        """Velas diarias OHLC para el chart de la Ficha.

        Nunca lanza y nunca devuelve un error HTTP: `bars` vacío con `degradation_reason` es la
        respuesta cuando el proveedor falla o el rango no tiene datos. El chart es una parte de la
        Ficha, no la Ficha entera — un histórico ausente no debe tumbar la pantalla (.cursorrules §2).
        """

        normalized = ticker.upper()
        try:
            bars = await self._polygon_client.get_daily_ohlc(
                normalized, start=start, end=end
            )
        except Exception as exc:  # noqa: BLE001 — `get_daily_ohlc` ya degrada sus propios
            # errores de proveedor a lista vacía sin lanzar; esto es una red de seguridad ante un
            # bug inesperado, no el camino esperado, y se registra explícito.
            logger.warning(
                "market_history_failed",
                extra={"ticker": normalized, "error": str(exc)},
            )
            return TickerHistory(
                ticker=normalized,
                start=start,
                end=end,
                bars=[],
                degradation_reason=_REASON_PROVIDER_FAILED,
            )

        if not bars:
            return TickerHistory(
                ticker=normalized,
                start=start,
                end=end,
                bars=[],
                degradation_reason=_REASON_NO_BARS,
            )

        return TickerHistory(
            ticker=normalized,
            start=start,
            end=end,
            bars=[
                OhlcBarOut(
                    t=bar.timestamp_ms,
                    o=float(bar.open),
                    h=float(bar.high),
                    l=float(bar.low),
                    c=float(bar.close),
                    v=float(bar.volume),
                )
                for bar in bars
            ],
        )
