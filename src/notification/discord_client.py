"""Cliente de despacho para Discord Webhooks: envío alternativo del Nodo 5 (Spec.md §3.5)."""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from types import TracebackType
from typing import Self

import httpx

from src.core.exceptions import (
    ProviderAuthenticationError,
    ProviderRateLimitError,
    ProviderResponseError,
    ProviderTimeoutError,
)
from src.core.http_utils import request_with_retries
from src.notification.schemas_raw import DiscordSendResult
from src.validation.domain_models import DataStatus

logger = logging.getLogger(__name__)

_PROVIDER_NAME = "discord"


class DiscordClient:
    def __init__(
        self,
        webhook_url: str,
        *,
        timeout_seconds: float = 15.0,
        max_retry_attempts: int = 3,
        http_client: httpx.AsyncClient | None = None,
    ) -> None:
        self._webhook_url = webhook_url
        self._max_retry_attempts = max_retry_attempts
        self._owns_client = http_client is None
        self._client = http_client or httpx.AsyncClient(
            timeout=httpx.Timeout(timeout_seconds)
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

    async def send_message(self, content: str) -> DiscordSendResult:
        """Ejecuta el webhook con `?wait=true` para recibir de vuelta el objeto del mensaje
        creado (y así poder reportar `message_id`); sin `wait=true` Discord responde 204 sin
        cuerpo. Cualquier fallo se traduce a `status=ERROR_API` con `message_id=None`.
        """

        sent_at = datetime.now(timezone.utc)

        try:
            response = await request_with_retries(
                self._client,
                "POST",
                f"{self._webhook_url}?wait=true",
                provider=_PROVIDER_NAME,
                max_attempts=self._max_retry_attempts,
                json={"content": content},
            )
        except (
            ProviderTimeoutError,
            ProviderRateLimitError,
            ProviderAuthenticationError,
            ProviderResponseError,
        ) as exc:
            logger.warning("discord_send_failed", extra={"error": str(exc)})
            return DiscordSendResult(
                status=DataStatus.ERROR_API, message_id=None, sent_at=sent_at
            )

        if response.status_code >= 300:
            logger.warning(
                "discord_webhook_rejected", extra={"status": response.status_code}
            )
            return DiscordSendResult(
                status=DataStatus.ERROR_API, message_id=None, sent_at=sent_at
            )

        try:
            payload = response.json()
        except ValueError:
            payload = None

        message_id = payload.get("id") if isinstance(payload, dict) else None

        return DiscordSendResult(
            status=DataStatus.OK,
            message_id=str(message_id) if message_id is not None else None,
            sent_at=sent_at,
        )
