"""Modelos Pydantic que reflejan la salida cruda de cada proveedor de despacho (Telegram,
Discord) — análogo a `ingestion/schemas_raw.py`, pero para el lado de salida del sistema.
"""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict

from src.validation.domain_models import DataStatus


class TelegramSendResult(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    status: DataStatus
    message_id: str | None
    sent_at: datetime


class DiscordSendResult(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    status: DataStatus
    message_id: str | None
    sent_at: datetime
