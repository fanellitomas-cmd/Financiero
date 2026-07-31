"""Servicio de precios en vivo para el Heatmap del Dashboard (Pantalla 1): envuelve
`PolygonClient.get_equity_snapshot`/`get_crypto_snapshot` (el mismo cliente que usa el Nodo 1
del motor, reutilizado — no uno nuevo) para exponer precio y % de variación del día de cada
ticker, sin pasar por la detección de alertas del Nodo 1 (que solo devuelve algo si se cruza
un umbral) — el Heatmap necesita el dato siempre, haya o no alerta.
"""

from __future__ import annotations

import asyncio
import logging

from app.models.enums import AssetType
from app.schemas.market import TickerQuote
from src.ingestion.polygon_client import PolygonClient
from src.validation.domain_models import DataStatus

logger = logging.getLogger(__name__)


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
