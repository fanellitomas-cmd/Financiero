"""Modelos Pydantic que reflejan la salida cruda de cada destino de despacho nativo (backend
propio, FCM) — análogo a `ingestion/schemas_raw.py`, pero para el lado de salida del sistema.
"""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict

from src.validation.domain_models import DataStatus


class InternalDispatchResult(BaseModel):
    """Salida de `InternalBackendClient.dispatch_alert`: si el backend propio aceptó y
    persistió la alerta, junto con el ID que le asignó (`alert_db_id` en el payload final).
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    status: DataStatus
    alert_id: str | None
    dispatched_at: datetime


class FCMSendResult(BaseModel):
    """Salida de `FCMClient.send_to_topic`: si Firebase Cloud Messaging aceptó el push."""

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    status: DataStatus
    message_name: str | None
    dispatched_at: datetime
