"""Motor y sesión async de SQLAlchemy 2.0. Un único engine reutilizado por toda la app
(.cursorrules §4: "un único cliente reutilizado por proveedor"), con `async_sessionmaker`
para obtener una sesión por request vía `app/api/deps.py::get_db`.
"""

from __future__ import annotations

from collections.abc import AsyncGenerator

from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase

from app.core.config import app_settings


class Base(DeclarativeBase):
    """Base declarativa de todos los modelos ORM (`app/models/`)."""


def create_engine() -> AsyncEngine:
    return create_async_engine(
        app_settings.database_url, echo=app_settings.database_echo
    )


engine = create_engine()
async_session_factory = async_sessionmaker(engine, expire_on_commit=False)


async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with async_session_factory() as session:
        yield session


def get_session_factory() -> async_sessionmaker[AsyncSession]:
    """Para los servicios que manejan su propia transacción (varias, en el caso de la
    sincronización del catálogo, que commitea por página) en vez de recibir una sesión ya
    abierta como `get_db`. Es una dependencia de FastAPI y no `async_session_factory` directo
    para que los tests puedan apuntarla a la base en memoria vía `dependency_overrides`.
    """

    return async_session_factory


async def create_all_tables(bound_engine: AsyncEngine = engine) -> None:
    """Crea las tablas si no existen. Atajo cómodo para desarrollo/tests; en producción el
    esquema se gestiona con las migraciones versionadas de Alembic (`alembic/`,
    `alembic upgrade head`), que es la fuente de verdad real del schema ahí.
    """

    async with bound_engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)
