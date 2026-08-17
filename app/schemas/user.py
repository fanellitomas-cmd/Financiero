"""Schemas Pydantic v2 de request/response para `Users` — nunca se expone `hashed_password`."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr, Field

from app.models.enums import PlanType


class UserCreate(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    email: EmailStr
    password: str = Field(min_length=8, max_length=128)

    # Obligatorio solo cuando el entorno define `REGISTRATION_INVITE_CODE`. Viaja opcional en el
    # schema para que el registro abierto de desarrollo siga funcionando sin mandar el campo, y la
    # exigencia vive en el endpoint, que es el único que conoce la configuración.
    invite_code: str | None = Field(default=None, max_length=200)


class UserLogin(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    email: EmailStr
    password: str


class UserRead(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", from_attributes=True)

    id: UUID
    email: EmailStr
    plan_type: PlanType
    created_at: datetime


class TokenResponse(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    access_token: str
    token_type: str = "bearer"
