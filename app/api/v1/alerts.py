"""`GET /api/v1/alerts` — Centro de Notificaciones: expone `AlertHistory` paginado, filtrado a
los tickers que el usuario autenticado sigue en su Watchlist (nunca el historial completo del
sistema, que mezclaría alertas de tickers de otros usuarios).
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query
from sqlalchemy import func, select

from app.api.deps import CurrentUser, DbSession
from app.core.config import app_settings
from app.models.alert_history import AlertHistory
from app.models.watchlist import WatchlistItem
from app.schemas.alert import AlertHistoryPage, AlertHistoryRead

router = APIRouter(prefix="/alerts", tags=["alerts"])


@router.get("", response_model=AlertHistoryPage)
async def list_alerts(
    current_user: CurrentUser,
    session: DbSession,
    limit: Annotated[
        int, Query(ge=1, le=100)
    ] = app_settings.alert_history_default_page_size,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> AlertHistoryPage:
    watched_tickers = select(WatchlistItem.ticker).where(
        WatchlistItem.user_id == current_user.id
    )

    total = await session.scalar(
        select(func.count())
        .select_from(AlertHistory)
        .where(AlertHistory.ticker.in_(watched_tickers))
    )

    rows = await session.scalars(
        select(AlertHistory)
        .where(AlertHistory.ticker.in_(watched_tickers))
        .order_by(AlertHistory.created_at.desc())
        .limit(limit)
        .offset(offset)
    )

    items = [AlertHistoryRead.model_validate(row) for row in rows.all()]
    return AlertHistoryPage(items=items, total=total or 0, limit=limit, offset=offset)
