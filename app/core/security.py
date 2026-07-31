"""Hashing de contraseñas (bcrypt) y emisión/verificación de JWT. Sin estado, sin I/O de red
— funciones puras sobre los settings de `app/core/config.py`.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from uuid import UUID

import bcrypt
import jwt
from pydantic import BaseModel, ConfigDict

from app.core.config import app_settings

_JWT_SUBJECT_CLAIM = "sub"
_JWT_EXPIRY_CLAIM = "exp"


class TokenPayload(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    user_id: UUID
    expires_at: datetime


def hash_password(plain_password: str) -> str:
    return bcrypt.hashpw(plain_password.encode("utf-8"), bcrypt.gensalt()).decode(
        "utf-8"
    )


def verify_password(plain_password: str, hashed_password: str) -> bool:
    try:
        return bcrypt.checkpw(
            plain_password.encode("utf-8"), hashed_password.encode("utf-8")
        )
    except ValueError:
        # hash malformado/corrupto — nunca se trata como "contraseña válida" por defecto
        return False


def create_access_token(user_id: UUID) -> str:
    expires_at = datetime.now(timezone.utc) + timedelta(
        minutes=app_settings.jwt_access_token_expire_minutes
    )
    payload = {_JWT_SUBJECT_CLAIM: str(user_id), _JWT_EXPIRY_CLAIM: expires_at}
    return jwt.encode(
        payload,
        app_settings.jwt_secret_key.get_secret_value(),
        algorithm=app_settings.jwt_algorithm,
    )


def decode_access_token(token: str) -> TokenPayload | None:
    """Devuelve `None` ante cualquier token inválido/expirado/malformado — nunca lanza hacia
    el llamador un detalle interno de la librería de JWT ni asume una identidad por defecto.
    """

    try:
        raw_payload = jwt.decode(
            token,
            app_settings.jwt_secret_key.get_secret_value(),
            algorithms=[app_settings.jwt_algorithm],
        )
    except jwt.InvalidTokenError:
        return None

    subject = raw_payload.get(_JWT_SUBJECT_CLAIM)
    expiry = raw_payload.get(_JWT_EXPIRY_CLAIM)
    if not isinstance(subject, str) or not isinstance(expiry, (int, float)):
        return None

    try:
        user_id = UUID(subject)
    except ValueError:
        return None

    return TokenPayload(
        user_id=user_id, expires_at=datetime.fromtimestamp(expiry, tz=timezone.utc)
    )
