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
from app.core.database import Base, get_db, get_session_factory
from app.main import app


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

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(
        transport=transport, base_url="http://test"
    ) as async_client:
        yield async_client

    app.dependency_overrides.clear()
