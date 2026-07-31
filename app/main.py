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

from app import models as _models  # noqa: F401  registra las tablas en Base.metadata
from app.api.v1.router import api_v1_router
from app.core.config import app_settings
from app.core.database import async_session_factory, create_all_tables, engine
from app.services.agent_runner_service import AgentRunnerService
from app.services.push_service import PushNotificationService, TickerConnectionManager
from app.services.scheduler import AgentScheduler
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

    ingestion_clients: list[
        PolygonClient | FMPClient | TavilyClient | GeminiClient
    ] = []
    if (
        agent_settings.polygon_api_key
        and agent_settings.fmp_api_key
        and agent_settings.tavily_api_key
        and agent_settings.gemini_api_key
    ):
        polygon = PolygonClient(
            agent_settings.polygon_api_key.get_secret_value(),
            base_url=agent_settings.polygon_base_url,
        )
        fmp = FMPClient(
            agent_settings.fmp_api_key.get_secret_value(),
            base_url=agent_settings.fmp_base_url,
        )
        tavily = TavilyClient(
            agent_settings.tavily_api_key.get_secret_value(),
            base_url=agent_settings.tavily_base_url,
        )
        gemini = GeminiClient(
            agent_settings.gemini_api_key.get_secret_value(),
            base_url=agent_settings.gemini_base_url,
            model=agent_settings.gemini_model,
        )
        ingestion_clients = [polygon, fmp, tavily, gemini]

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
                    "/api/v1/internal/trigger-agent devolverá 503 hasta configurarlas"
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
    application.include_router(api_v1_router)
    return application


app = create_app()
