"""`GET /api/v1/tickers` — catálogo de acciones sincronizado desde Polygon, filtrable por
bolsa y buscable por símbolo o nombre. Alimenta el selector de activos del cliente y la
preferencia NASDAQ/NYSE que el usuario ya elige en la app.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query

from app.api.deps import CurrentUser, TickerCatalog
from app.core.config import app_settings
from app.models.enums import ExchangeType
from app.schemas.ticker import TickerPage, TickerRead

router = APIRouter(prefix="/tickers", tags=["tickers"])


@router.get("", response_model=TickerPage)
async def list_tickers(
    current_user: CurrentUser,
    catalog: TickerCatalog,
    exchange: Annotated[ExchangeType | None, Query()] = None,
    q: Annotated[str | None, Query(min_length=1, max_length=64)] = None,
    limit: Annotated[int, Query(ge=1, le=200)] = app_settings.ticker_default_page_size,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> TickerPage:
    items, total = await catalog.search(
        exchange=exchange, query=q, limit=limit, offset=offset
    )
    return TickerPage(
        items=[TickerRead.model_validate(item) for item in items],
        total=total,
        limit=limit,
        offset=offset,
    )
