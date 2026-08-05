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

from app.api.deps import (
    CurrentUser,
    TickerCatalog,
    TickerIntelligenceDep,
    TickerSearchDep,
)
from app.core.config import app_settings
from app.models.enums import ExchangeType
from app.schemas.intelligence import TickerIntelligence
from app.schemas.search import NaturalSearchRequest, NaturalSearchResponse
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


@router.post(
    "/search-nl",
    response_model=NaturalSearchResponse,
    summary="Búsqueda de tickers en lenguaje natural",
)
async def search_tickers_natural_language(
    payload: NaturalSearchRequest,
    # `current_user` antes que el servicio: FastAPI resuelve en orden de firma, y así un pedido sin
    # token corta con 401 sin revelar el estado de configuración del backend.
    current_user: CurrentUser,
    search: TickerSearchDep,
) -> NaturalSearchResponse:
    """Traduce una consulta escrita ("tecnológicas baratas y sin mucha deuda") a criterios
    estructurados con IA, y filtra el catálogo local más los ratios reales del proveedor.

    El modelo interpreta la intención; el filtrado lo hace el backend contra sus propios datos.
    Pedirle al modelo que elija los símbolos sería pedirle que recuerde de memoria el P/E de cada
    empresa — ver `app/services/ticker_search_service.py`.

    Siempre 200 con estructura válida. Sin credenciales de IA cae a búsqueda por texto sobre símbolo
    y nombre (`criteria_source=TEXT_FALLBACK`); sin proveedor de fundamentales, los criterios
    numéricos viajan en `unapplied_criteria` — porque una lista filtrada solo por sector, presentada
    como si cumpliera "P/E menor a 20", sería una respuesta falsa.

    Es POST y no GET aunque sea una lectura: la consulta es texto libre de hasta 500 caracteres (un
    query string es el lugar equivocado para eso, y quedaría en los logs de cada proxy del camino) y
    la operación gasta una llamada al modelo, algo que un GET no debería hacer.
    """

    return await search.search(payload.query, limit=payload.limit)


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
