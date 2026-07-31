"""`GET /api/v1/market/quotes` — precio y % de variación en vivo de cada ticker de la
Watchlist del usuario autenticado, para el Heatmap del Dashboard (Pantalla 1).
"""

from __future__ import annotations

from fastapi import APIRouter
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession, MarketData
from app.models.watchlist import WatchlistItem
from app.schemas.market import TickerQuote

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
