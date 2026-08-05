"""Punto de entrada de la API FastAPI. El `lifespan` arma, una única vez por proceso, los
clientes HTTP de larga vida del motor (Polygon/FMP/Tavily/Gemini) y los servicios de la app
(DB, push), y los guarda en `app.state` para que las dependencias de `app/api/deps.py` los
inyecten por request sin recrearlos (.cursorrules §4).

Correr en desarrollo:
    uvicorn app.main:app --reload
"""

from __future__ import annotations

import logging
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app import models as _models  # noqa: F401  registra las tablas en Base.metadata
from app.api.v1.router import api_v1_router
from app.core.config import app_settings
from app.core.database import async_session_factory, create_all_tables, engine
from app.services.agent_runner_service import AgentRunnerService
from app.services.chat_service import ChatService
from app.services.financial_translator_service import FinancialTranslatorService
from app.services.market_data_service import MarketDataService
from app.services.market_summary_service import MarketSummaryService
from app.services.portfolio_audit_service import PortfolioAuditService
from app.services.push_service import PushNotificationService, TickerConnectionManager
from app.services.scheduler import AgentScheduler
from app.services.ticker_intelligence_service import TickerIntelligenceService
from app.services.ticker_search_service import TickerSearchService
from src.composition import build_ingestion_backed_dependencies
from src.core.config import settings as agent_settings
from src.ingestion.fmp_client import FMPClient
from src.ingestion.gemini_client import GeminiClient
from src.ingestion.polygon_client import PolygonClient
from src.ingestion.tavily_client import TavilyClient
from src.notification.fcm_client import FCMClient

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    await create_all_tables()

    connection_manager = TickerConnectionManager()
    app.state.connection_manager = connection_manager

    fcm_client: FCMClient | None = None
    if agent_settings.fcm_project_id and agent_settings.fcm_access_token:
        fcm_client = FCMClient(
            agent_settings.fcm_project_id,
            agent_settings.fcm_access_token.get_secret_value(),
        )

    push_service = PushNotificationService(
        async_session_factory,
        fcm_client=fcm_client,
        connection_manager=connection_manager,
    )
    app.state.push_service = push_service

    # Cada cliente se construye UNA vez si su propia credencial está presente, y se reutiliza
    # tanto para su servicio standalone (quotes/chat) como para el motor completo — nunca dos
    # instancias del mismo cliente (.cursorrules §4). El motor completo (AgentRunnerService)
    # necesita los cuatro; los servicios standalone solo necesitan el suyo.
    ingestion_clients: list[
        PolygonClient | FMPClient | TavilyClient | GeminiClient
    ] = []

    polygon: PolygonClient | None = None
    if agent_settings.polygon_api_key:
        polygon = PolygonClient(
            agent_settings.polygon_api_key.get_secret_value(),
            base_url=agent_settings.polygon_base_url,
        )
        ingestion_clients.append(polygon)

    fmp: FMPClient | None = None
    if agent_settings.fmp_api_key:
        fmp = FMPClient(
            agent_settings.fmp_api_key.get_secret_value(),
            base_url=agent_settings.fmp_base_url,
        )
        ingestion_clients.append(fmp)

    tavily: TavilyClient | None = None
    if agent_settings.tavily_api_key:
        tavily = TavilyClient(
            agent_settings.tavily_api_key.get_secret_value(),
            base_url=agent_settings.tavily_base_url,
        )
        ingestion_clients.append(tavily)

    gemini: GeminiClient | None = None
    if agent_settings.gemini_api_key:
        gemini = GeminiClient(
            agent_settings.gemini_api_key.get_secret_value(),
            base_url=agent_settings.gemini_base_url,
            model=agent_settings.gemini_model,
        )
        ingestion_clients.append(gemini)

    market_data_service: MarketDataService | None = None
    if polygon is not None:
        market_data_service = MarketDataService(polygon)
    else:
        logger.warning(
            "market_data_not_configured",
            extra={
                "hint": "falta POLYGON_API_KEY; /api/v1/market/quotes devolverá 503"
            },
        )
    app.state.market_data_service = market_data_service

    # El resumen depende de Polygon para los datos duros y usa Gemini solo para la narrativa:
    # con Polygon y sin Gemini el servicio se construye igual y sirve las alzas y bajas con
    # `ai_narrative_available=False` (ver `market_summary_service.py`).
    market_summary_service: MarketSummaryService | None = None
    if polygon is not None:
        market_summary_service = MarketSummaryService(
            polygon,
            async_session_factory,
            gemini_client=gemini,
            cache_ttl_seconds=app_settings.market_summary_cache_ttl_seconds,
            movers_per_direction=app_settings.market_summary_movers_per_direction,
        )
        if gemini is None:
            logger.warning(
                "market_summary_narrative_not_configured",
                extra={
                    "hint": (
                        "falta GEMINI_API_KEY; /api/v1/market/summary servirá alzas y bajas "
                        "sin resumen de IA"
                    )
                },
            )
    else:
        logger.warning(
            "market_summary_not_configured",
            extra={
                "hint": "falta POLYGON_API_KEY; /api/v1/market/summary devolverá 503"
            },
        )
    app.state.market_summary_service = market_summary_service

    if gemini is not None:
        # `quote_provider`/`market_summary` son opcionales: le dan al chat la cotización en vivo
        # del ticker preguntado y el estado general del mercado cuando no hay ticker. Si Polygon
        # no está configurado quedan en None y el chat sigue respondiendo con lo que haya en la
        # DB, declarando en el prompt que no tiene esos datos.
        app.state.chat_service = ChatService(
            gemini,
            async_session_factory,
            quote_provider=market_data_service,
            market_summary=market_summary_service,
        )
    else:
        logger.warning(
            "chat_not_configured",
            extra={"hint": "falta GEMINI_API_KEY; /api/v1/chat devolverá 503"},
        )
        app.state.chat_service = None

    # La Ficha de Inteligencia Profunda se instancia SIEMPRE, con los clientes que haya: cada uno
    # ausente degrada solo su bloque (fundamentales / síntesis / proyecciones) y la respuesta sigue
    # teniendo forma válida. Es el único servicio que no puede quedar en None.
    app.state.ticker_intelligence_service = TickerIntelligenceService(
        fmp_client=fmp,
        tavily_client=tavily,
        gemini_client=gemini,
        cache_ttl_seconds=app_settings.ticker_intelligence_cache_ttl_seconds,
    )
    if fmp is None or gemini is None:
        logger.warning(
            "ticker_intelligence_partially_configured",
            extra={
                "hint": (
                    "faltan FMP_API_KEY y/o GEMINI_API_KEY; "
                    "/api/v1/tickers/{ticker}/intelligence servirá los bloques que pueda con "
                    "availability=UNAVAILABLE en el resto"
                )
            },
        )

    # La búsqueda en lenguaje natural y el Traductor Financiero también se instancian SIEMPRE. La
    # búsqueda tiene el catálogo local (dato propio) para filtrar por texto/sector/bolsa aunque
    # falten las dos credenciales, y el traductor responde `available=False` con el motivo — un 503
    # obligaría al cliente a traducir "no configurado" a un aviso, que es lo que el servicio ya hace.
    app.state.ticker_search_service = TickerSearchService(
        async_session_factory,
        gemini_client=gemini,
        fmp_client=fmp,
        max_candidates=app_settings.search_nl_max_candidates,
        max_metric_lookups=app_settings.search_nl_max_metric_lookups,
    )
    app.state.financial_translator_service = FinancialTranslatorService(
        gemini_client=gemini,
        cache_ttl_seconds=app_settings.financial_translator_cache_ttl_seconds,
        max_cache_entries=app_settings.financial_translator_max_cache_entries,
    )
    if gemini is None:
        logger.warning(
            "conversational_features_not_configured",
            extra={
                "hint": (
                    "falta GEMINI_API_KEY; /api/v1/tickers/search-nl cae a búsqueda por texto y "
                    "/api/v1/ai/translate-financial responde available=false"
                )
            },
        )

    # La Auditoría de Portafolio también se instancia SIEMPRE, por el mismo motivo: la
    # distribución por sector y la concentración se calculan sobre la watchlist del usuario, que
    # es dato propio de la app. Sin FMP los sectores caen a "Sin clasificar", sin Polygon las
    # correlaciones caen a la heurística por sector, y sin Gemini no hay narrativa — cada ausencia
    # degrada su bloque y ninguna vacía la auditoría.
    app.state.portfolio_audit_service = PortfolioAuditService(
        async_session_factory,
        fmp_client=fmp,
        polygon_client=polygon,
        gemini_client=gemini,
        cache_ttl_seconds=app_settings.portfolio_audit_cache_ttl_seconds,
        correlation_window_days=app_settings.portfolio_audit_correlation_window_days,
        correlation_threshold=app_settings.portfolio_audit_correlation_threshold,
        min_correlation_observations=app_settings.portfolio_audit_min_observations,
        max_history_tickers=app_settings.portfolio_audit_max_history_tickers,
    )
    if fmp is None or polygon is None or gemini is None:
        logger.warning(
            "portfolio_audit_partially_configured",
            extra={
                "hint": (
                    "faltan FMP_API_KEY/POLYGON_API_KEY/GEMINI_API_KEY; "
                    "/api/v1/watchlist/audit servirá los bloques que pueda con su "
                    "degradation_reason explicando el resto"
                )
            },
        )

    if (
        polygon is not None
        and fmp is not None
        and tavily is not None
        and gemini is not None
    ):
        # Sin internal_backend_client/fcm_client acá: el despacho real (persistir en
        # AlertHistory + avisar a los watchers) lo hace esta misma app vía PushNotificationService
        # después de recibir el PushNotificationPayload del grafo — evitar wirear el Nodo 5
        # con clientes de despacho propios haría que el push se disparara dos veces.
        graph_dependencies = build_ingestion_backed_dependencies(
            polygon, fmp, tavily, gemini_client=gemini
        )
        app.state.agent_runner_service = AgentRunnerService(
            graph_dependencies, push_service, async_session_factory
        )
    else:
        logger.warning(
            "agent_engine_not_configured",
            extra={
                "hint": (
                    "faltan POLYGON_API_KEY/FMP_API_KEY/TAVILY_API_KEY/GEMINI_API_KEY; "
                    "/api/v1/internal/trigger-agent y el scheduler quedan inactivos hasta "
                    "configurarlas"
                )
            },
        )
        app.state.agent_runner_service = None

    scheduler: AgentScheduler | None = None
    if app.state.agent_runner_service is not None and app_settings.scheduler_enabled:
        scheduler = AgentScheduler(
            app.state.agent_runner_service,
            interval_minutes=app_settings.scheduler_interval_minutes,
            market_hours_only=app_settings.scheduler_market_hours_only,
        )
        scheduler.start()
    app.state.scheduler = scheduler

    try:
        yield
    finally:
        if scheduler is not None:
            scheduler.shutdown()
        for client in ingestion_clients:
            await client.aclose()
        if fcm_client is not None:
            await fcm_client.aclose()
        await engine.dispose()


def create_app() -> FastAPI:
    application = FastAPI(
        title="Financiero API",
        description="Backend de la plataforma: autenticación, watchlists y disparo del motor de LangGraph.",
        version="1.0.0",
        lifespan=lifespan,
    )
    application.add_middleware(
        CORSMiddleware,
        allow_origins=app_settings.cors_allowed_origins,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    application.include_router(api_v1_router)
    return application


app = create_app()
