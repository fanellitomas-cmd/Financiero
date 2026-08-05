"""Endpoints de tickers:

- `GET /api/v1/tickers` — catálogo de acciones sincronizado desde Polygon, filtrable por bolsa y
  buscable por símbolo o nombre. Alimenta el selector de activos del cliente y la preferencia
  NASDAQ/NYSE que el usuario ya elige en la app.
- `GET /api/v1/tickers/{ticker}/intelligence` — Ficha de Inteligencia Profunda: fundamentales,
  síntesis de reportes oficiales y proyecciones multi-horizonte.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query

from app.api.deps import CurrentUser, TickerCatalog, TickerIntelligenceDep
from app.core.config import app_settings
from app.models.enums import ExchangeType
from app.schemas.intelligence import TickerIntelligence
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


@router.get("/{ticker}/intelligence", response_model=TickerIntelligence)
async def get_ticker_intelligence(
    ticker: str,
    # `current_user` antes que el servicio: FastAPI resuelve en orden de firma, y así un pedido sin
    # token corta con 401 sin revelar el estado de configuración del backend.
    current_user: CurrentUser,
    catalog: TickerCatalog,
    intelligence: TickerIntelligenceDep,
    force_refresh: Annotated[
        bool,
        Query(
            description=(
                "Ignora la caché y recompila la Ficha. Es la operación más cara del sistema "
                "(una llamada al LLM más cuatro a proveedores): el uso normal debe respetar la caché."
            ),
        ),
    ] = False,
) -> TickerIntelligence:
    """Ficha de Inteligencia Profunda: fundamentales, síntesis de reportes oficiales y proyecciones
    a corto, mediano y largo plazo.

    Siempre 200 con una estructura válida. Los tres bloques degradan por separado y cada uno lleva
    su `availability` más un motivo legible, así que un entorno sin credenciales devuelve una Ficha
    completa en forma y explícitamente vacía en contenido — no un 503 que el cliente tendría que
    traducir. Ver `app/services/ticker_intelligence_service.py`.

    El símbolo NO se valida contra el catálogo: un ticker recién listado (o una cripto, que el
    catálogo de acciones no incluye) igual tiene fundamentales y noticias. Solo se consulta el
    catálogo para enriquecer la respuesta con el nombre de la empresa cuando está.
    """

    company_name = await catalog.find_name(ticker)
    return await intelligence.get_intelligence(
        ticker, company_name=company_name, force_refresh=force_refresh
    )
