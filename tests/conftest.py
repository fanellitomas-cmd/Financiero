"""Fixtures compartidas para los tests de la API FastAPI (`app/`): un engine SQLite en
memoria por test (aislado, sin tocar el `financiero.db` de desarrollo) y un
`httpx.AsyncClient` contra la app vía `ASGITransport` — sin levantar un servidor real.
"""

from __future__ import annotations

from collections.abc import AsyncGenerator

import httpx
import pytest
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import StaticPool

from app import models as _models  # noqa: F401  registra las tablas en Base.metadata
from app.core.config import app_settings
from app.core.database import Base, get_db, get_session_factory
from app.core.rate_limit import InMemoryLoginRateLimiter, RateLimitConfig
from app.main import app
from app.services.ai_lab_service import AiLabService
from app.services.corporate_service import CorporateService
from app.services.financial_translator_service import FinancialTranslatorService
from app.services.portfolio_audit_service import PortfolioAuditService
from app.services.portfolio_builder_service import PortfolioBuilderService
from app.services.ticker_intelligence_service import TickerIntelligenceService
from app.services.ticker_search_service import TickerSearchService


@pytest.fixture
async def db_session_factory() -> AsyncGenerator[
    async_sessionmaker[AsyncSession], None
]:
    engine = create_async_engine(
        "sqlite+aiosqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    try:
        yield session_factory
    finally:
        await engine.dispose()


@pytest.fixture
async def client(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> AsyncGenerator[httpx.AsyncClient, None]:
    async def _override_get_db() -> AsyncGenerator[AsyncSession, None]:
        async with db_session_factory() as session:
            yield session

    app.dependency_overrides[get_db] = _override_get_db
    # Los servicios que manejan su propia transacción (TickerCatalogService) reciben el factory,
    # no una sesión ya abierta — sin este override apuntarían al SQLite de desarrollo en vez de
    # a la base en memoria del test.
    app.dependency_overrides[get_session_factory] = lambda: db_session_factory
    app.state.agent_runner_service = None
    app.state.chat_service = None
    app.state.market_data_service = None
    app.state.market_summary_service = None
    # La Ficha de Inteligencia se instancia sin ningún cliente: todos sus bloques degradan y los
    # tests que quieran el camino con datos la sobreescriben con los dobles que necesiten.
    app.state.ticker_intelligence_service = TickerIntelligenceService(
        system_prompt="Prompt de prueba."
    )
    # Ídem la Auditoría de Portafolio: sin clientes, calcula distribución y concentración sobre la
    # watchlist del test y declara degradado el resto. Los tests que quieran sectores reales o
    # narrativa la sobreescriben con los dobles que necesiten.
    app.state.portfolio_audit_service = PortfolioAuditService(
        db_session_factory, system_prompt="Prompt de prueba."
    )
    # Búsqueda NL sin Gemini ni FMP: cae a búsqueda por texto sobre el catálogo del test. Los tests
    # que quieran interpretación o filtros por ratios la sobreescriben con sus dobles.
    app.state.ticker_search_service = TickerSearchService(
        db_session_factory, system_prompt="Prompt de prueba."
    )
    # Traductor sin Gemini: responde `available=False` con su motivo.
    app.state.financial_translator_service = FinancialTranslatorService(
        system_prompt="Prompt de prueba."
    )
    # Corporate Hub sin ningún cliente: las cuatro vistas degradan con su motivo. Los tests que
    # quieran datos la sobreescriben con los dobles que necesiten.
    app.state.corporate_service = CorporateService(system_prompt="Prompt de prueba.")
    # Laboratorio Financiero sin ningún cliente: las dos vistas degradan con su motivo. Los tests que
    # quieran datos la sobreescriben con los dobles que necesiten.
    app.state.ai_lab_service = AiLabService(
        analysis_prompt="Prompt de prueba.", scenario_prompt="Prompt de prueba."
    )
    # Constructor de Portafolios sin proveedor de precios: las posiciones con `custom_price` se
    # calculan enteras y las que dependen del mercado quedan sin unidades con su motivo. Los tests que
    # quieran precios en vivo lo sobreescriben con sus dobles.
    app.state.portfolio_builder_service = PortfolioBuilderService(db_session_factory)
    # Limitador de login fresco por test (backend en memoria), para que el conteo de intentos no se
    # arrastre entre tests. Umbrales por defecto de los settings.
    app.state.login_rate_limiter = InMemoryLoginRateLimiter(
        RateLimitConfig(
            max_email_attempts=app_settings.login_rate_limit_max_email_attempts,
            max_ip_attempts=app_settings.login_rate_limit_max_ip_attempts,
            window_seconds=app_settings.login_rate_limit_window_seconds,
        )
    )

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(
        transport=transport, base_url="http://test"
    ) as async_client:
        yield async_client

    app.dependency_overrides.clear()
