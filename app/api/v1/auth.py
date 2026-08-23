"""`POST /auth/register` y `POST /auth/login` — autenticación con JWT."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import select

import hmac

from app.api.deps import DbSession, client_ip, get_login_rate_limiter
from app.core.config import app_settings
from app.core.rate_limit import LoginRateLimiter
from app.core.security import (
    create_access_token,
    dummy_password_check,
    hash_password,
    verify_password,
)
from app.models.user import User
from app.schemas.user import TokenResponse, UserCreate, UserLogin, UserRead

router = APIRouter(prefix="/auth", tags=["auth"])


def _check_invite_code(provided: str | None) -> None:
    """Verifica el código de invitación cuando el entorno lo exige.

    Sin `REGISTRATION_INVITE_CODE` configurado el registro queda abierto, que es lo que corresponde
    en desarrollo. Con el código puesto, un alta sin él o con el equivocado es 403 y no 401: no es
    que las credenciales estén mal, es que esta instancia no acepta altas de cualquiera.

    La comparación es `hmac.compare_digest` y no `==` para no filtrar el largo ni el prefijo del
    código por el tiempo que tarda en fallar.
    """

    expected = app_settings.registration_invite_code
    if expected is None:
        return

    forbidden = HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail=(
            "Esta instancia necesita un código de invitación para crear cuentas. Pedíselo a quien "
            "te compartió el link."
        ),
    )
    if provided is None or not hmac.compare_digest(
        provided.strip(), expected.get_secret_value()
    ):
        raise forbidden


@router.post("/register", response_model=UserRead, status_code=status.HTTP_201_CREATED)
async def register(payload: UserCreate, session: DbSession) -> User:
    # El código se verifica ANTES de tocar la base: sin esto, un atacante podría enumerar qué emails
    # ya tienen cuenta leyendo el 409, sin conocer el código.
    _check_invite_code(payload.invite_code)

    existing = await session.scalar(select(User).where(User.email == payload.email))
    if existing is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Ya existe una cuenta con ese email.",
        )

    user = User(email=payload.email, hashed_password=hash_password(payload.password))
    session.add(user)
    await session.commit()
    await session.refresh(user)
    return user


@router.post("/login", response_model=TokenResponse)
async def login(
    payload: UserLogin,
    request: Request,
    session: DbSession,
    rate_limiter: Annotated[LoginRateLimiter, Depends(get_login_rate_limiter)],
) -> TokenResponse:
    invalid_credentials = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED, detail="Email o contraseña inválidos."
    )

    ip = client_ip(request)
    # El límite se chequea ANTES de tocar la base o correr bcrypt: un atacante frenado no debe poder
    # ni siquiera gastarnos un hash por intento.
    decision = await rate_limiter.check(payload.email, ip)
    if not decision.allowed:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Demasiados intentos de inicio de sesión. Probá de nuevo en un rato.",
            headers={"Retry-After": str(decision.retry_after_seconds)},
        )

    user = await session.scalar(select(User).where(User.email == payload.email))
    if user is None:
        # Se corre una verificación bcrypt igual (contra un hash señuelo) aunque el email no exista:
        # sin esto, esta rama vuelve en ~2 ms y la de una contraseña incorrecta en ~270 ms, y esa
        # diferencia de tiempo enumera qué emails están registrados pese al 401 y el mensaje idéntico.
        dummy_password_check(payload.password)
        await rate_limiter.record_failure(payload.email, ip)
        raise invalid_credentials
    if not verify_password(payload.password, user.hashed_password):
        await rate_limiter.record_failure(payload.email, ip)
        raise invalid_credentials

    # Un login exitoso limpia el contador del email: quien se equivocó una vez y entró no arrastra
    # el fallo hacia el próximo intento.
    await rate_limiter.record_success(payload.email, ip)
    return TokenResponse(access_token=create_access_token(user.id))
