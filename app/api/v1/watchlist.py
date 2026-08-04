"""`GET/POST/DELETE /watchlist` — el usuario gestiona qué Acciones/Cripto sigue. Todo scoped a
`CurrentUser`: nunca se lee ni se borra un item de otro usuario, aunque se conozca su UUID.
"""

from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, status
from sqlalchemy import or_, select

from app.api.deps import CurrentUser, DbSession, TickerCatalog
from app.models.enums import AssetType, ExchangeType
from app.models.watchlist import WatchlistItem
from app.schemas.watchlist import (
    WatchlistItemCreate,
    WatchlistItemRead,
    WatchlistItemUpdate,
)

router = APIRouter(prefix="/watchlist", tags=["watchlist"])


@router.get("", response_model=list[WatchlistItemRead])
async def list_watchlist(
    current_user: CurrentUser,
    session: DbSession,
    exchange: Annotated[ExchangeType | None, Query()] = None,
) -> list[WatchlistItem]:
    """`exchange` opcional para que el cliente pueda mostrar solo la bolsa que el usuario
    eligió. Sin el parámetro devuelve todo.

    Las CRIPTO quedan siempre visibles, incluso con un filtro de bolsa activo: no cotizan en
    NASDAQ ni en NYSE, así que "filtrar por bolsa" no es una pregunta que se les pueda aplicar
    — esconderlas sería tratar la ausencia de bolsa como si fuera otra bolsa, y alguien que
    sigue BTC lo vería desaparecer al elegir NASDAQ.

    Las ACCIONES sin bolsa resuelta (`exchange = NULL`, símbolos que todavía no están en el
    catálogo) sí se esconden con un filtro activo: ahí la bolsa existe pero no se conoce, que
    es distinto de no tener ninguna.
    """

    filters = [WatchlistItem.user_id == current_user.id]
    if exchange is not None:
        filters.append(
            or_(
                WatchlistItem.exchange == exchange,
                WatchlistItem.asset_type == AssetType.CRYPTO,
            )
        )

    result = await session.scalars(select(WatchlistItem).where(*filters))
    return list(result.all())


@router.post("", response_model=WatchlistItemRead, status_code=status.HTTP_201_CREATED)
async def add_to_watchlist(
    payload: WatchlistItemCreate,
    current_user: CurrentUser,
    session: DbSession,
    catalog: TickerCatalog,
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

    # La bolsa se resuelve acá desde el catálogo local, no se le pide al usuario. Que no
    # aparezca NO es un error: una cripto nunca va a estar en el catálogo de acciones, y una
    # acción cuyo símbolo todavía no se sincronizó tampoco. En esos casos el item se guarda con
    # `exchange = None` en vez de rechazarse — si esto fuera un 404, un catálogo vacío (recién
    # instalado, sin `sync_tickers` corrido) volvería inusable toda la watchlist.
    exchange = (
        await catalog.find_exchange(payload.ticker)
        if payload.asset_type == AssetType.STOCK
        else None
    )

    item = WatchlistItem(
        user_id=current_user.id,
        ticker=payload.ticker.upper(),
        asset_type=payload.asset_type,
        alert_threshold_pct=payload.alert_threshold_pct,
        enable_beginner_mode=payload.enable_beginner_mode,
        exchange=exchange,
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
