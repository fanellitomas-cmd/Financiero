"""Endpoints de mercado del Dashboard (Pantalla 1):

- `GET /api/v1/market/quotes` — precio y % de variación en vivo de cada ticker de la Watchlist
  del usuario autenticado, para el Heatmap.
- `GET /api/v1/market/summary` — Resumen Diario: mayores alzas y bajas de NASDAQ/NYSE más un
  resumen ejecutivo generado por Gemini, cacheado en memoria.
"""

from __future__ import annotations

from fastapi import APIRouter, Query
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession, MarketData, MarketSummaryDep
from app.models.watchlist import WatchlistItem
from app.schemas.market import MarketSummary, TickerQuote

router = APIRouter(prefix="/market", tags=["market"])


@router.get("/quotes", response_model=list[TickerQuote])
async def get_watchlist_quotes(
    current_user: CurrentUser, session: DbSession, market_data: MarketData
) -> list[TickerQuote]:
    rows = (
        await session.execute(
            select(WatchlistItem.ticker, WatchlistItem.asset_type)
            .where(WatchlistItem.user_id == current_user.id)
            .distinct()
        )
    ).all()

    return await market_data.get_quotes(
        [(ticker, asset_type) for ticker, asset_type in rows]
    )


@router.get("/summary", response_model=MarketSummary)
async def get_market_summary(
    current_user: CurrentUser,
    market_summary: MarketSummaryDep,
    force_refresh: bool = Query(
        default=False,
        description=(
            "Ignora la caché y recompila el resumen. Pensado para depurar o para un botón "
            "explícito de 'actualizar'; el uso normal debe respetar la caché."
        ),
    ),
) -> MarketSummary:
    """El resumen es global (el mismo para todos los usuarios), no por-usuario: no depende de la
    Watchlist de quien pregunta. Se pide autenticación igual, para no exponer llamadas a Gemini
    a cualquiera que conozca el URL.
    """

    return await market_summary.get_summary(force_refresh=force_refresh)
