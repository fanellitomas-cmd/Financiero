"""Dependencias compartidas de FastAPI: sesión de DB, usuario autenticado (JWT), y
verificación de la API key interna para el endpoint del Cron/Scheduler.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, Header, HTTPException, Request, status
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import app_settings
from app.core.database import get_db
from app.core.security import decode_access_token
from app.models.user import User
from app.services.agent_runner_service import AgentRunnerService

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
