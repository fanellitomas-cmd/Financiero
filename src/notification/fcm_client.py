"""Cliente de despacho vía Firebase Cloud Messaging, API HTTP v1 (Nodo 5, Spec.md §3.5).

NOTA DE DISEÑO: usamos la API REST de FCM directo por `httpx` en vez del SDK `firebase_admin`.
`firebase_admin.messaging` es síncrono por dentro (usa `google-api-core`/`requests`), así que
llamarlo desde una corrutina bloquearía el event loop salvo que se envuelva en
`asyncio.to_thread` — y aun así, seguiría siendo "otro cliente HTTP" fuera del patrón
`httpx.AsyncClient` + reintentos centralizados que usa el resto del proyecto (.cursorrules
§4). La API REST v1 es funcionalmente equivalente y nos deja 100% en async nativo.

Requiere un access token OAuth2 ya vigente (`Settings.fcm_access_token`); renovarlo (vía una
service account, típicamente con `google-auth`) es responsabilidad de la infraestructura que
construye este cliente, no de este módulo — igual que con las demás credenciales del proyecto.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from types import TracebackType
from typing import Any, Self

import httpx

from src.core.exceptions import (
    ProviderAuthenticationError,
    ProviderRateLimitError,
    ProviderResponseError,
    ProviderTimeoutError,
)
from src.core.http_utils import request_with_retries
from src.notification.schemas_raw import FCMSendResult
from src.validation.domain_models import DataStatus, PushNotificationPayload

logger = logging.getLogger(__name__)

_PROVIDER_NAME = "fcm"


class FCMClient:
    def __init__(
        self,
        project_id: str,
        access_token: str,
        *,
        base_url: str = "https://fcm.googleapis.com/v1",
        timeout_seconds: float = 15.0,
        max_retry_attempts: int = 3,
        http_client: httpx.AsyncClient | None = None,
    ) -> None:
        self._project_id = project_id
        self._access_token = access_token
        self._max_retry_attempts = max_retry_attempts
        self._owns_client = http_client is None
        self._client = http_client or httpx.AsyncClient(
            base_url=base_url, timeout=httpx.Timeout(timeout_seconds)
        )

    async def aclose(self) -> None:
        if self._owns_client:
            await self._client.aclose()

    async def __aenter__(self) -> Self:
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        await self.aclose()

    async def send_to_topic(
        self, topic: str, payload: PushNotificationPayload
    ) -> FCMSendResult:
        """Publica `payload` al tópico `topic` (ej. `alerts_NVDA`) — broadcast para todos los
        clientes suscriptos a ese ticker, sin importar el usuario. `data` va todo en string
        (requisito de FCM).
        """

        return await self._send({"topic": topic}, payload, log_target=topic)

    async def send_to_token(
        self, token: str, payload: PushNotificationPayload
    ) -> FCMSendResult:
        """Envía `payload` a un único dispositivo (`DeviceToken.fcm_token`) — push
        personalizado directo, a diferencia del broadcast por tópico de `send_to_topic`.
        """

        return await self._send({"token": token}, payload, log_target=token)

    async def _send(
        self,
        target: dict[str, str],
        payload: PushNotificationPayload,
        *,
        log_target: str,
    ) -> FCMSendResult:
        dispatched_at = datetime.now(timezone.utc)
        path = f"/projects/{self._project_id}/messages:send"
        body: dict[str, Any] = {
            "message": {
                **target,
                "notification": {"title": payload.title, "body": payload.short_summary},
                "data": {
                    "notification_id": payload.notification_id,
                    "ticker": payload.ticker,
                    "asset_type": payload.asset_type,
                    "urgency_level": payload.urgency_level.value,
                    "action_url": payload.action_url,
                    "degraded_raw_data_only": str(
                        payload.degraded_raw_data_only
                    ).lower(),
                },
            }
        }

        try:
            response = await request_with_retries(
                self._client,
                "POST",
                path,
                provider=_PROVIDER_NAME,
                max_attempts=self._max_retry_attempts,
                headers={"Authorization": f"Bearer {self._access_token}"},
                json=body,
            )
        except (
            ProviderTimeoutError,
            ProviderRateLimitError,
            ProviderAuthenticationError,
            ProviderResponseError,
        ) as exc:
            logger.warning(
                "fcm_send_failed", extra={"target": log_target, "error": str(exc)}
            )
            return FCMSendResult(
                status=DataStatus.ERROR_API,
                message_name=None,
                dispatched_at=dispatched_at,
            )

        try:
            data = response.json()
        except ValueError:
            return FCMSendResult(
                status=DataStatus.ERROR_API,
                message_name=None,
                dispatched_at=dispatched_at,
            )

        message_name = data.get("name") if isinstance(data, dict) else None
        if message_name is None:
            return FCMSendResult(
                status=DataStatus.ERROR_API,
                message_name=None,
                dispatched_at=dispatched_at,
            )

        return FCMSendResult(
            status=DataStatus.OK,
            message_name=str(message_name),
            dispatched_at=dispatched_at,
        )
