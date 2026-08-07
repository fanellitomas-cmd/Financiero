"""`/api/v1/corporate/*` — el Corporate Intelligence Hub.

Cuatro vistas de solo lectura sobre datos de proveedores externos: calendario de balances, histórico
de sorpresas, biblioteca de reportes SEC y feed de noticias. Ninguna guarda nada.

**Ningún endpoint devuelve 503 por falta de credenciales.** Los cuatro responden 200 con su
estructura válida, la lista vacía, `availability=UNAVAILABLE` y un motivo legible. Un 503 obligaría
al cliente a traducir "no configurado" a un aviso, que es exactamente lo que la respuesta ya trae —
y le impediría distinguirlo de "esta semana no reporta nadie", que es la otra lista vacía posible.
"""

from __future__ import annotations

from datetime import date, timedelta
from typing import Annotated

from fastapi import APIRouter, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import CorporateServiceDep, CurrentUser, DbSession
from app.models.ticker import Ticker
from app.schemas.corporate import (
    CorporateNewsFeed,
    EarningsCalendar,
    EarningsHistory,
    FilingsResponse,
    NewsCategory,
    NewsSentiment,
)
from app.schemas.portfolio_audit import PortfolioSector
from app.services.corporate_service import (
    default_calendar_range,
    normalize_for_matching,
)
from app.services.portfolio_audit_service import normalize_sector, provider_sector_keys

router = APIRouter(prefix="/corporate", tags=["corporate"])

# Tope del rango del calendario. Sin él, un cliente puede pedir cinco años de balances de todo el
# mercado en un solo request — decenas de miles de filas que ningún cliente puede mostrar.
_MAX_CALENDAR_DAYS = 92


@router.get(
    "/earnings-calendar",
    response_model=EarningsCalendar,
    summary="Calendario de próximos balances",
)
async def get_earnings_calendar(
    current_user: CurrentUser,
    corporate: CorporateServiceDep,
    session: DbSession,
    from_date: Annotated[
        date | None,
        Query(
            alias="from",
            description="Desde (inclusive). Por defecto, hoy.",
        ),
    ] = None,
    to_date: Annotated[
        date | None,
        Query(alias="to", description="Hasta (inclusive). Por defecto, 7 días."),
    ] = None,
    ticker: Annotated[
        str | None,
        Query(min_length=1, max_length=20, description="Solo este símbolo."),
    ] = None,
    sector: Annotated[
        str | None,
        Query(
            min_length=2,
            max_length=64,
            description=(
                "Solo los símbolos de este sector, según el catálogo local. Un símbolo que el "
                "catálogo no conoce queda AFUERA y se cuenta en `unclassified_by_sector`."
            ),
        ),
    ] = None,
) -> EarningsCalendar:
    """Balances programados y publicados en un rango de fechas.

    `ticker` y `sector` no se combinan: si vienen los dos, gana `ticker`. Son dos preguntas
    distintas —"cuándo reporta esta empresa" y "qué reporta este sector"— y su intersección casi
    siempre es una sola fila o ninguna, lo que se leería como un bug.
    """

    start, end = _resolve_range(from_date, to_date)

    sector_tickers: frozenset[str] | None = None
    if ticker is None and sector is not None:
        sector_tickers = await _tickers_in_sector(session, sector)

    return await corporate.get_earnings_calendar(
        from_date=start,
        to_date=end,
        ticker=ticker,
        sector_tickers=sector_tickers,
    )


def _resolve_range(from_date: date | None, to_date: date | None) -> tuple[date, date]:
    """Rango efectivo, con los defaults y el tope aplicados.

    Un rango invertido se corrige dando vuelta los extremos en vez de rechazarlo con un 422: es un
    error de tipeo obvio cuya intención no es ambigua, y devolver un error por eso solo agrega un
    viaje.
    """

    default_start, default_end = default_calendar_range()
    start = from_date or default_start
    end = to_date or (
        start + timedelta(days=7) if from_date is not None else default_end
    )

    if end < start:
        start, end = end, start
    if (end - start).days > _MAX_CALENDAR_DAYS:
        end = start + timedelta(days=_MAX_CALENDAR_DAYS)
    return start, end


async def _tickers_in_sector(session: AsyncSession, sector: str) -> frozenset[str]:
    """Símbolos del catálogo local que pertenecen al sector pedido.

    Se resuelve acá y no en el servicio porque es una consulta a datos PROPIOS: pedirle el sector al
    proveedor por cada símbolo del calendario serían decenas de requests dentro de un request HTTP,
    y el catálogo ya tiene la columna.

    El sector del usuario se normaliza al vocabulario del producto y se expande a las variantes que
    usan los proveedores ("Tecnología", "Technology", "Information Technology"): quien filtra por
    "tecnologia" espera los mismos símbolos que quien filtra por "Technology".
    """

    resolved = _resolve_sector(sector)
    variants = (
        {value.lower() for value in provider_sector_keys(resolved)}
        if resolved is not None
        else set()
    )
    # El texto crudo entra igual: si el catálogo guardó un sector que ninguna de las dos tablas
    # conoce, filtrar por ese mismo texto tiene que seguir funcionando.
    variants.add(sector.strip().lower())

    result = await session.execute(
        select(Ticker.symbol, Ticker.sector).where(Ticker.sector.is_not(None))
    )
    return frozenset(
        symbol.upper()
        for symbol, ticker_sector in result.all()
        if ticker_sector is not None and ticker_sector.strip().lower() in variants
    )


def _resolve_sector(raw: str) -> PortfolioSector | None:
    """El sector pedido, llevado al vocabulario del producto. `None` si no lo reconoce ninguno.

    Se prueban los DOS vocabularios porque los dos son legítimos en un query string: el del producto
    (`TECNOLOGIA`, que es el que la UI muestra y el que devuelve la auditoría de cartera) y el del
    proveedor (`Technology`, que es el que aparece en la ficha del activo). Aceptar solo uno haría
    que el mismo filtro funcione en una pantalla y devuelva vacío en la otra.
    """

    candidate = (
        normalize_for_matching(raw).strip().replace("-", "_").replace(" ", "_").upper()
    )
    try:
        return PortfolioSector(candidate)
    except ValueError:
        pass

    mapped = normalize_sector(raw)
    return None if mapped is PortfolioSector.SIN_CLASIFICAR else mapped


@router.get(
    "/earnings-history/{ticker}",
    response_model=EarningsHistory,
    summary="Histórico de sorpresas de un símbolo",
)
async def get_earnings_history(
    ticker: str,
    current_user: CurrentUser,
    corporate: CorporateServiceDep,
    limit: Annotated[
        int,
        Query(ge=1, le=24, description="Cuántos trimestres reportados traer."),
    ] = 8,
) -> EarningsHistory:
    """Trimestres ya publicados, del más reciente al más viejo, con su sorpresa de EPS e ingresos.

    La tasa de aciertos se calcula sobre los trimestres MEDIDOS (los que tenían estimación), no sobre
    todos: un trimestre sin estimación no se puede contar ni como acierto ni como fallo, y meterlo en
    el denominador haría parecer menos consistente a la empresa por un hueco del proveedor.
    """

    return await corporate.get_earnings_history(ticker, limit=limit)


@router.get(
    "/filings/{ticker}",
    response_model=FilingsResponse,
    summary="Reportes SEC de un símbolo",
)
async def get_filings(
    ticker: str,
    current_user: CurrentUser,
    corporate: CorporateServiceDep,
    limit: Annotated[int, Query(ge=1, le=50)] = 10,
    summarize: Annotated[
        bool,
        Query(
            description=(
                "Genera una síntesis ejecutiva con IA para cada reporte. Cuesta una llamada al "
                "modelo, por eso es opt-in."
            ),
        ),
    ] = False,
) -> FilingsResponse:
    """Biblioteca de reportes con su enlace oficial y, si se pide, una síntesis.

    La síntesis se arma sobre los METADATOS del reporte (tipo y fecha), no sobre su texto: el backend
    no descarga los documentos de la SEC. El prompt se lo dice al modelo explícitamente y le prohíbe
    afirmar qué dice el reporte — puede explicar qué suele contener ese tipo de documento y qué
    buscar adentro. Lo otro sería pedirle que invente.
    """

    return await corporate.get_filings(ticker, limit=limit, summarize=summarize)


@router.get(
    "/news",
    response_model=CorporateNewsFeed,
    summary="Feed de noticias y rumores corporativos",
)
async def get_corporate_news(
    current_user: CurrentUser,
    corporate: CorporateServiceDep,
    ticker: Annotated[
        str | None,
        Query(
            min_length=1, max_length=20, description="Solo noticias de este símbolo."
        ),
    ] = None,
    category: Annotated[
        NewsCategory | None,
        Query(description="RUMOR, CORPORATE, REGULATORY, EARNINGS o MARKET."),
    ] = None,
    sentiment: Annotated[
        NewsSentiment | None,
        Query(description="BULLISH, BEARISH o NEUTRAL."),
    ] = None,
    limit: Annotated[int, Query(ge=1, le=50)] = 20,
) -> CorporateNewsFeed:
    """Noticias recientes, clasificadas por categoría y sentimiento.

    **La clasificación es un heurístico por palabras clave, y cada ítem lo declara** en
    `classification_source`. Un titular etiquetado BEARISH no es el veredicto de un analista: es una
    pista derivada del texto, y el cliente tiene que poder presentarla como tal.

    `total_before_filters` viaja siempre para que una lista corta no sea ambigua: con tres filtros
    combinables, "1 noticia" puede ser todo lo que hay o el resultado de un filtro que quedó puesto.
    """

    return await corporate.get_news(
        ticker=ticker,
        category=category,
        sentiment=sentiment,
        limit=limit,
    )
