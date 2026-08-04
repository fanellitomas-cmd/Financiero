"""Endpoints de mercado del Dashboard (Pantalla 1):

- `GET /api/v1/market/quotes` — precio y % de variación en vivo de cada ticker de la Watchlist
  del usuario autenticado, para el Heatmap.
- `GET /api/v1/market/summary` — Resumen Diario: mayores alzas y bajas de NASDAQ/NYSE más un
  resumen ejecutivo generado por Gemini, cacheado en memoria.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from typing import Annotated

from fastapi import APIRouter, HTTPException, Query, status
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession, MarketData, MarketSummaryDep
from app.models.watchlist import WatchlistItem
from app.schemas.market import MarketSummary, TickerHistory, TickerQuote

router = APIRouter(prefix="/market", tags=["market"])

# Tope del rango histórico. Son velas DIARIAS: cinco años ya son ~1250 velas, más de lo que
# cualquier chart puede dibujar de forma legible, y el tope evita que un `days` arbitrario se
# traduzca en un pedido enorme al proveedor.
_MAX_HISTORY_DAYS = 1825


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
    force_refresh: Annotated[
        bool,
        Query(
            description=(
                "Ignora la caché y recompila el resumen. Pensado para depurar o para un botón "
                "explícito de 'actualizar'; el uso normal debe respetar la caché."
            ),
        ),
    ] = False,
) -> MarketSummary:
    """El resumen es global (el mismo para todos los usuarios), no por-usuario: no depende de la
    Watchlist de quien pregunta. Se pide autenticación igual, para no exponer llamadas a Gemini
    a cualquiera que conozca el URL.
    """

    return await market_summary.get_summary(force_refresh=force_refresh)


@router.get("/history/{ticker}", response_model=TickerHistory)
async def get_ticker_history(
    ticker: str,
    # `current_user` ANTES de `market_data`: FastAPI resuelve las dependencias en el orden de la
    # firma, y así un pedido sin token corta con 401 sin llegar a revelar si el proveedor está
    # configurado (que es lo que diría el 503 de `market_data`).
    current_user: CurrentUser,
    market_data: MarketData,
    days: Annotated[
        int,
        Query(
            ge=1,
            le=_MAX_HISTORY_DAYS,
            description=(
                "Días hacia atrás desde hoy. Ignorado si se pasan `start`/`end`."
            ),
        ),
    ] = 30,
    start: Annotated[
        date | None,
        Query(description="Inicio del rango (YYYY-MM-DD). Requiere `end`."),
    ] = None,
    end: Annotated[
        date | None,
        Query(description="Fin del rango (YYYY-MM-DD). Requiere `start`."),
    ] = None,
) -> TickerHistory:
    """Velas diarias OHLC para el chart de la Ficha.

    Siempre responde 200: si el proveedor falla, está bloqueado o no está configurado, devuelve
    `bars: []` con un `degradation_reason` legible. Un chart vacío es una degradación del chart, no
    un fallo de la pantalla — a diferencia de `/market/quotes`, que sí devuelve 503 cuando Polygon
    no está configurado porque ahí el heatmap ES el contenido.

    Dos formas de pedir el rango: `days` (simple, el default de la app) o `start`+`end` explícitos
    para cuando el usuario hace zoom out. Pasar solo uno de los dos es un 422 y no un rango a
    medias inventado por el servidor.
    """

    if (start is None) != (end is None):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="`start` y `end` se pasan juntos, o ninguno de los dos (usá `days`).",
        )

    if start is not None and end is not None:
        if start > end:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="`start` no puede ser posterior a `end`.",
            )
        if (end - start).days > _MAX_HISTORY_DAYS:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail=(
                    f"El rango no puede exceder {_MAX_HISTORY_DAYS} días "
                    "(son velas diarias; un rango mayor no aporta al chart)."
                ),
            )
        range_start, range_end = start, end
    else:
        # `date.today()` en UTC para que coincida con el horario que usa el proveedor: con la fecha
        # local, un usuario al este de UTC pediría un "hoy" que en el mercado todavía no empezó.
        range_end = datetime.now(timezone.utc).date()
        range_start = range_end - timedelta(days=days)

    return await market_data.get_history(ticker, start=range_start, end=range_end)
