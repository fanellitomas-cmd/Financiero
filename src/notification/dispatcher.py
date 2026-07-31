"""Nodo 5 — Generador de Salida nativo (Spec.md §3.5). Implementa `NotificationDispatcher`:
arma el `PushNotificationPayload` con `payload_builder` y lo despacha hacia el backend propio
y/o FCM. Sin terceros (Telegram/Discord) — la app consume sus propias notificaciones.
"""

from __future__ import annotations

import logging

from src.notification.fcm_client import FCMClient
from src.notification.internal_backend_client import InternalBackendClient
from src.notification.payload_builder import build_push_payload
from src.validation.domain_models import (
    AssetProjection,
    DataStatus,
    MarketAlert,
    PushNotificationPayload,
    UserProfile,
    WatchedAsset,
)

logger = logging.getLogger(__name__)

_DEFAULT_ACTION_URL_TEMPLATE = "financiero://asset/{ticker}"
_DEFAULT_FCM_TOPIC_TEMPLATE = "alerts_{ticker}"


class NativePushDispatcher:
    def __init__(
        self,
        *,
        internal_backend_client: InternalBackendClient | None = None,
        fcm_client: FCMClient | None = None,
        fcm_topic_template: str = _DEFAULT_FCM_TOPIC_TEMPLATE,
        action_url_template: str = _DEFAULT_ACTION_URL_TEMPLATE,
    ) -> None:
        if internal_backend_client is None and fcm_client is None:
            logger.warning(
                "notification_dispatcher_no_channels_configured",
                extra={
                    "hint": "ni backend propio ni FCM configurados; nunca se despachará nada"
                },
            )

        self._backend = internal_backend_client
        self._fcm = fcm_client
        self._fcm_topic_template = fcm_topic_template
        self._action_url_template = action_url_template

    async def render_and_send(
        self,
        asset: WatchedAsset,
        user_profile: UserProfile,
        alert: MarketAlert | None,
        projection: AssetProjection | None,
        degraded_raw_data_only: bool,
    ) -> PushNotificationPayload:
        payload = build_push_payload(
            asset=asset,
            user_profile=user_profile,
            alert=alert,
            projection=projection,
            degraded_raw_data_only=degraded_raw_data_only,
            action_url_template=self._action_url_template,
        )

        alert_db_id: str | None = None
        push_dispatched = False

        if self._backend is not None:
            backend_result = await self._backend.dispatch_alert(payload)
            if backend_result.status == DataStatus.OK:
                alert_db_id = backend_result.alert_id
                push_dispatched = True
            else:
                logger.warning(
                    "internal_backend_dispatch_failed", extra={"ticker": asset.ticker}
                )

        if self._fcm is not None:
            topic = self._fcm_topic_template.format(ticker=asset.ticker)
            fcm_result = await self._fcm.send_to_topic(topic, payload)
            if fcm_result.status == DataStatus.OK:
                push_dispatched = True
            else:
                logger.warning(
                    "fcm_dispatch_failed",
                    extra={"ticker": asset.ticker, "topic": topic},
                )

        if not push_dispatched:
            logger.error(
                "notification_dispatch_failed_all_channels",
                extra={"ticker": asset.ticker},
            )

        return payload.model_copy(
            update={"push_dispatched": push_dispatched, "alert_db_id": alert_db_id}
        )
