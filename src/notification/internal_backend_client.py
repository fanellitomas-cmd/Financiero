"""Cliente de despacho hacia el backend propio (Nodo 5, Spec.md §3.5). Registra la alerta en
`POST {base_url}{dispatch_path}` (por defecto `/api/v1/internal/alerts/dispatch`) — el backend
propio decide luego cómo llegar al dispositivo del usuario (push nativo, bandeja in-app,
email, etc.). No hay terceros tipo Telegram/Discord en este flujo.
"""

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
from src.notification.schemas_raw import InternalDispatchResult
from src.validation.domain_models import DataStatus, PushNotificationPayload

logger = logging.getLogger(__name__)

_PROVIDER_NAME = "internal_backend"


class InternalBackendClient:
    def __init__(
        self,
        base_url: str,
        *,
        dispatch_path: str = "/api/v1/internal/alerts/dispatch",
        api_key: str | None = None,
        timeout_seconds: float = 15.0,
        max_retry_attempts: int = 3,
        http_client: httpx.AsyncClient | None = None,
    ) -> None:
        self._dispatch_path = dispatch_path
        self._api_key = api_key
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

    async def dispatch_alert(
        self, payload: PushNotificationPayload
    ) -> InternalDispatchResult:
        """Registra `payload` en el backend propio. Un fallo de red, autenticación, o una
        respuesta sin `alert_id` se traduce a `status=ERROR_API` — nunca se inventa un ID.
        """

        dispatched_at = datetime.now(timezone.utc)
        headers = {"Authorization": f"Bearer {self._api_key}"} if self._api_key else {}

        try:
            response = await request_with_retries(
                self._client,
                "POST",
                self._dispatch_path,
                provider=_PROVIDER_NAME,
                max_attempts=self._max_retry_attempts,
                headers=headers,
                json=payload.model_dump(mode="json"),
            )
        except (
            ProviderTimeoutError,
            ProviderRateLimitError,
            ProviderAuthenticationError,
            ProviderResponseError,
        ) as exc:
            logger.warning(
                "internal_backend_dispatch_failed",
                extra={"ticker": payload.ticker, "error": str(exc)},
            )
            return InternalDispatchResult(
                status=DataStatus.ERROR_API, alert_id=None, dispatched_at=dispatched_at
            )

        try:
            data = response.json()
        except ValueError:
            return InternalDispatchResult(
                status=DataStatus.ERROR_API, alert_id=None, dispatched_at=dispatched_at
            )

        alert_id = data.get("alert_id") if isinstance(data, dict) else None
        if alert_id is None:
            logger.warning(
                "internal_backend_response_missing_alert_id",
                extra={"ticker": payload.ticker},
            )
            return InternalDispatchResult(
                status=DataStatus.ERROR_API, alert_id=None, dispatched_at=dispatched_at
            )

        return InternalDispatchResult(
            status=DataStatus.OK, alert_id=str(alert_id), dispatched_at=dispatched_at
        )
