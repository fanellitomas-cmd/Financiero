"""Cliente de despacho para la API de Telegram Bot: envía un mensaje ya formateado (Nodo 5,
Spec.md §3.5). Solo envía y parsea la respuesta — el formateo del texto vive en
`message_templates.py`, y qué se envía lo decide `dispatcher.py`.
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
from src.notification.schemas_raw import TelegramSendResult
from src.validation.domain_models import DataStatus

logger = logging.getLogger(__name__)

_PROVIDER_NAME = "telegram"


class TelegramClient:
    def __init__(
        self,
        bot_token: str,
        *,
        base_url: str = "https://api.telegram.org",
        timeout_seconds: float = 15.0,
        max_retry_attempts: int = 3,
        http_client: httpx.AsyncClient | None = None,
    ) -> None:
        self._bot_token = bot_token
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

    async def send_message(
        self, chat_id: str, text: str, *, parse_mode: str = "MarkdownV2"
    ) -> TelegramSendResult:
        """Envía `text` (ya escapado para `parse_mode` por el llamador) al chat indicado.
        Cualquier fallo de red, rate limit, o respuesta `ok=false` de Telegram se traduce a
        `status=ERROR_API` con `message_id=None` — nunca se inventa un ID de mensaje.
        """

        path = f"/bot{self._bot_token}/sendMessage"
        sent_at = datetime.now(timezone.utc)

        try:
            response = await request_with_retries(
                self._client,
                "POST",
                path,
                provider=_PROVIDER_NAME,
                max_attempts=self._max_retry_attempts,
                json={"chat_id": chat_id, "text": text, "parse_mode": parse_mode},
            )
        except (
            ProviderTimeoutError,
            ProviderRateLimitError,
            ProviderAuthenticationError,
            ProviderResponseError,
        ) as exc:
            logger.warning(
                "telegram_send_failed", extra={"chat_id": chat_id, "error": str(exc)}
            )
            return TelegramSendResult(
                status=DataStatus.ERROR_API, message_id=None, sent_at=sent_at
            )

        try:
            payload = response.json()
        except ValueError:
            return TelegramSendResult(
                status=DataStatus.ERROR_API, message_id=None, sent_at=sent_at
            )

        if not isinstance(payload, dict) or payload.get("ok") is not True:
            logger.warning(
                "telegram_api_rejected",
                extra={"chat_id": chat_id, "description": _error_description(payload)},
            )
            return TelegramSendResult(
                status=DataStatus.ERROR_API, message_id=None, sent_at=sent_at
            )

        result = payload.get("result")
        message_id = result.get("message_id") if isinstance(result, dict) else None

        return TelegramSendResult(
            status=DataStatus.OK,
            message_id=str(message_id) if message_id is not None else None,
            sent_at=sent_at,
        )


def _error_description(payload: Any) -> str:
    if isinstance(payload, dict):
        description = payload.get("description")
        if isinstance(description, str):
            return description
    return "respuesta inesperada"
