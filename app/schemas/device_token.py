"""Schemas Pydantic v2 de request/response para `DeviceTokens`."""

from __future__ import annotations

from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import DevicePlatform


class DeviceTokenCreate(BaseModel):
    # strict=False (default) deliberado, igual que en app/schemas/watchlist.py: valida JSON
    # externo de un request HTTP donde el enum llega como string, no como instancia Python.
    model_config = ConfigDict(extra="forbid")

    fcm_token: str = Field(min_length=1, max_length=4096)
    platform: DevicePlatform


class DeviceTokenRead(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", from_attributes=True)

    id: UUID
    fcm_token: str
    platform: DevicePlatform
