"""Dependencias compartidas de FastAPI: sesión de DB, usuario autenticado (JWT), y
verificación de la API key interna para el endpoint del Cron/Scheduler.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, Header, HTTPException, Request, status
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.config import app_settings
from app.core.database import get_db, get_session_factory
from app.core.security import decode_access_token
from app.models.user import User
from app.services.agent_runner_service import AgentRunnerService
from app.services.chat_service import ChatService
from app.services.market_data_service import MarketDataService
from app.services.market_summary_service import MarketSummaryService
from app.services.portfolio_audit_service import PortfolioAuditService
from app.services.ticker_catalog_service import TickerCatalogService
from app.services.ticker_intelligence_service import TickerIntelligenceService
from app.services.watchlist_alert_service import WatchlistAlertRuleService

_oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/v1/auth/login")

DbSession = Annotated[AsyncSession, Depends(get_db)]


async def get_current_user(
    token: Annotated[str, Depends(_oauth2_scheme)], session: DbSession
) -> User:
    unauthorized = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Credenciales inválidas o expiradas.",
        headers={"WWW-Authenticate": "Bearer"},
    )

    token_payload = decode_access_token(token)
    if token_payload is None:
        raise unauthorized

    user = await session.get(User, token_payload.user_id)
    if user is None:
        raise unauthorized

    return user


CurrentUser = Annotated[User, Depends(get_current_user)]


async def verify_internal_api_key(
    x_internal_api_key: Annotated[str | None, Header()] = None,
) -> None:
    if x_internal_api_key != app_settings.internal_api_key.get_secret_value():
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="API key interna inválida o ausente.",
        )


def get_agent_runner_service(request: Request) -> AgentRunnerService:
    """El `AgentRunnerService` se construye una vez en el lifespan de la app (`app/main.py`)
    porque envuelve clientes HTTP de larga vida (Polygon/FMP/Tavily/Gemini/backend/FCM) que
    deben reutilizarse, no recrearse por request (.cursorrules §4). Si el motor no tiene
    credenciales configuradas, el lifespan nunca lo instancia — acá se falla explícito (503)
    en vez de simular una corrida que no ocurrió.
    """

    service = getattr(request.app.state, "agent_runner_service", None)
    if not isinstance(service, AgentRunnerService):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=(
                "El motor de LangGraph no está configurado en este entorno "
                "(faltan credenciales de POLYGON/FMP/TAVILY/GEMINI en .env)."
            ),
        )
    return service


AgentRunner = Annotated[AgentRunnerService, Depends(get_agent_runner_service)]


def get_chat_service(request: Request) -> ChatService:
    """Igual que `get_agent_runner_service`: el `ChatService` se construye una única vez en
    el lifespan (`app/main.py`), envolviendo el mismo `GeminiClient` reutilizado. Si Gemini
    no está configurado, el lifespan nunca lo instancia — 503 explícito acá.
    """

    service = getattr(request.app.state, "chat_service", None)
    if not isinstance(service, ChatService):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="El chat no está configurado en este entorno (falta GEMINI_API_KEY en .env).",
        )
    return service


ChatServiceDep = Annotated[ChatService, Depends(get_chat_service)]


def get_market_data_service(request: Request) -> MarketDataService:
    """Igual que `get_agent_runner_service`: se construye una única vez en el lifespan,
    envolviendo el mismo `PolygonClient` reutilizado. 503 explícito si Polygon no está
    configurado.
    """

    service = getattr(request.app.state, "market_data_service", None)
    if not isinstance(service, MarketDataService):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=(
                "Los precios en vivo no están configurados en este entorno "
                "(falta POLYGON_API_KEY en .env)."
            ),
        )
    return service


MarketData = Annotated[MarketDataService, Depends(get_market_data_service)]


def get_market_summary_service(request: Request) -> MarketSummaryService:
    """Igual que los demás servicios de larga vida: se construye una única vez en el lifespan.

    El 503 acá es por falta de POLYGON_API_KEY, no de Gemini: sin datos de mercado el endpoint no
    tiene nada que devolver, mientras que sin Gemini el servicio existe y sirve las alzas y bajas
    sin narrativa (`ai_narrative_available=False`).
    """

    service = getattr(request.app.state, "market_summary_service", None)
    if not isinstance(service, MarketSummaryService):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=(
                "El resumen de mercado no está configurado en este entorno "
                "(falta POLYGON_API_KEY en .env)."
            ),
        )
    return service


MarketSummaryDep = Annotated[MarketSummaryService, Depends(get_market_summary_service)]


def get_ticker_catalog_service(
    session_factory: Annotated[
        async_sessionmaker[AsyncSession], Depends(get_session_factory)
    ],
) -> TickerCatalogService:
    """A diferencia de los otros servicios, este no envuelve ningún cliente HTTP de larga vida
    (solo consulta la DB local), así que se construye por request — es apenas una referencia al
    session factory — y nunca puede fallar con 503 por falta de credenciales. El cliente de
    Polygon solo aparece en la sincronización (`scripts/sync_tickers.py`), no acá.
    """

    return TickerCatalogService(session_factory)


TickerCatalog = Annotated[TickerCatalogService, Depends(get_ticker_catalog_service)]


def get_ticker_intelligence_service(request: Request) -> TickerIntelligenceService:
    """El `TickerIntelligenceService` se construye una vez en el lifespan, envolviendo los mismos
    clientes de FMP/Tavily/Gemini que ya usa el motor.

    A diferencia de los otros servicios, este **no** devuelve 503 por falta de credenciales: se
    instancia siempre, porque cada cliente ausente degrada solo su bloque de la Ficha y la respuesta
    sigue teniendo forma válida. Un 503 acá obligaría al cliente a traducir "no configurado" a una
    Ficha vacía, que es exactamente el trabajo que el servicio ya hace.
    """

    service = getattr(request.app.state, "ticker_intelligence_service", None)
    if not isinstance(service, TickerIntelligenceService):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="La Ficha de Inteligencia Profunda no está disponible en este momento.",
        )
    return service


# `...Dep` y no `TickerIntelligence` a secas: ese nombre ya es el schema de respuesta
# (`app/schemas/intelligence.py`), y tener los dos en scope confundiría en cada endpoint.
TickerIntelligenceDep = Annotated[
    TickerIntelligenceService, Depends(get_ticker_intelligence_service)
]


def get_portfolio_audit_service(request: Request) -> PortfolioAuditService:
    """La Auditoría de Portafolio se construye una vez en el lifespan, reutilizando los mismos
    clientes de FMP/Polygon/Gemini que ya usa el motor.

    Igual que la Ficha de Inteligencia Profunda, **no** devuelve 503 por falta de credenciales: la
    distribución por sector y la concentración se calculan sobre la watchlist del usuario, que es
    dato propio, y cada cliente ausente degrada solo su bloque.
    """

    service = getattr(request.app.state, "portfolio_audit_service", None)
    if not isinstance(service, PortfolioAuditService):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="La auditoría de portafolio no está disponible en este momento.",
        )
    return service


# `...Dep` por el mismo motivo que arriba: `PortfolioAudit` ya es el schema de respuesta.
PortfolioAuditDep = Annotated[
    PortfolioAuditService, Depends(get_portfolio_audit_service)
]


def get_watchlist_alert_rule_service(
    session_factory: Annotated[
        async_sessionmaker[AsyncSession], Depends(get_session_factory)
    ],
) -> WatchlistAlertRuleService:
    """Como `TickerCatalogService`, se construye por request: no envuelve ningún cliente HTTP de
    larga vida (solo lee y escribe la base local) y nunca puede fallar con 503 por credenciales.
    """

    return WatchlistAlertRuleService(session_factory)


WatchlistAlertRules = Annotated[
    WatchlistAlertRuleService, Depends(get_watchlist_alert_rule_service)
]
