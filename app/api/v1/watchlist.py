"""`GET/POST/DELETE /watchlist` — el usuario gestiona qué Acciones/Cripto sigue. Todo scoped a
`CurrentUser`: nunca se lee ni se borra un item de otro usuario, aunque se conozca su UUID.
"""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, HTTPException, status
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.models.watchlist import WatchlistItem
from app.schemas.watchlist import (
    WatchlistItemCreate,
    WatchlistItemRead,
    WatchlistItemUpdate,
)

router = APIRouter(prefix="/watchlist", tags=["watchlist"])


@router.get("", response_model=list[WatchlistItemRead])
async def list_watchlist(
    current_user: CurrentUser, session: DbSession
) -> list[WatchlistItem]:
    result = await session.scalars(
        select(WatchlistItem).where(WatchlistItem.user_id == current_user.id)
    )
    return list(result.all())


@router.post("", response_model=WatchlistItemRead, status_code=status.HTTP_201_CREATED)
async def add_to_watchlist(
    payload: WatchlistItemCreate, current_user: CurrentUser, session: DbSession
) -> WatchlistItem:
    existing = await session.scalar(
        select(WatchlistItem).where(
            WatchlistItem.user_id == current_user.id,
            WatchlistItem.ticker == payload.ticker.upper(),
        )
    )
    if existing is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"{payload.ticker.upper()} ya está en tu watchlist.",
        )

    item = WatchlistItem(
        user_id=current_user.id,
        ticker=payload.ticker.upper(),
        asset_type=payload.asset_type,
        alert_threshold_pct=payload.alert_threshold_pct,
        enable_beginner_mode=payload.enable_beginner_mode,
    )
    session.add(item)
    await session.commit()
    await session.refresh(item)
    return item


@router.patch("/{item_id}", response_model=WatchlistItemRead)
async def update_watchlist_item(
    item_id: UUID,
    payload: WatchlistItemUpdate,
    current_user: CurrentUser,
    session: DbSession,
) -> WatchlistItem:
    item = await session.get(WatchlistItem, item_id)
    if item is None or item.user_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Item de watchlist no encontrado.",
        )

    if payload.alert_threshold_pct is not None:
        item.alert_threshold_pct = payload.alert_threshold_pct
    if payload.enable_beginner_mode is not None:
        item.enable_beginner_mode = payload.enable_beginner_mode

    await session.commit()
    await session.refresh(item)
    return item


@router.delete("/{item_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_from_watchlist(
    item_id: UUID, current_user: CurrentUser, session: DbSession
) -> None:
    item = await session.get(WatchlistItem, item_id)
    if item is None or item.user_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Item de watchlist no encontrado.",
        )

    await session.delete(item)
    await session.commit()
