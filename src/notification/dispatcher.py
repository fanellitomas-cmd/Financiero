"""Nodo 5 — Generador de Salida (Spec.md §3.5). Implementa `NotificationDispatcher`: formatea
con `message_templates` y despacha con el primer canal configurado que funcione (Telegram,
luego Discord). No decide ni calcula nada — solo conoce el resultado final ya auditado por el
Guardrail (.cursorrules §3).
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone

from src.notification.discord_client import DiscordClient
from src.notification.message_templates import (
    render_discord_message,
    render_telegram_message,
)
from src.notification.telegram_client import TelegramClient
from src.validation.domain_models import (
    AssetProjection,
    DataStatus,
    MarketAlert,
    NotificationChannel,
    NotificationPayload,
    UserProfile,
    WatchedAsset,
)

logger = logging.getLogger(__name__)


class ChannelNotificationDispatcher:
    def __init__(
        self,
        *,
        telegram_client: TelegramClient | None = None,
        telegram_chat_id: str | None = None,
        discord_client: DiscordClient | None = None,
    ) -> None:
        if telegram_client is not None and telegram_chat_id is None:
            raise ValueError(
                "telegram_chat_id es requerido si se provee telegram_client."
            )

        self._telegram_client = telegram_client
        self._telegram_chat_id = telegram_chat_id
        self._discord_client = discord_client

        if telegram_client is None and discord_client is None:
            logger.warning(
                "notification_dispatcher_no_channels_configured",
                extra={
                    "hint": "ningún canal (Telegram/Discord) configurado; nunca se enviará nada"
                },
            )

    async def render_and_send(
        self,
        asset: WatchedAsset,
        user_profile: UserProfile,
        alert: MarketAlert | None,
        projection: AssetProjection | None,
        degraded_raw_data_only: bool,
    ) -> NotificationPayload:
        telegram_text = render_telegram_message(
            asset=asset,
            user_profile=user_profile,
            alert=alert,
            projection=projection,
            degraded_raw_data_only=degraded_raw_data_only,
        )

        sent_at = datetime.now(timezone.utc)
        notification_sent = False
        message_id: str | None = None
        channel: NotificationChannel | None = None

        if self._telegram_client is not None and self._telegram_chat_id is not None:
            telegram_result = await self._telegram_client.send_message(
                self._telegram_chat_id, telegram_text
            )
            if telegram_result.status == DataStatus.OK:
                notification_sent = True
                message_id = telegram_result.message_id
                channel = NotificationChannel.TELEGRAM
                sent_at = telegram_result.sent_at
            else:
                logger.warning(
                    "telegram_dispatch_failed", extra={"ticker": asset.ticker}
                )

        if not notification_sent and self._discord_client is not None:
            discord_text = render_discord_message(
                asset=asset,
                user_profile=user_profile,
                alert=alert,
                projection=projection,
                degraded_raw_data_only=degraded_raw_data_only,
            )
            discord_result = await self._discord_client.send_message(discord_text)
            if discord_result.status == DataStatus.OK:
                notification_sent = True
                message_id = discord_result.message_id
                channel = NotificationChannel.DISCORD
                sent_at = discord_result.sent_at
            else:
                logger.warning(
                    "discord_dispatch_failed", extra={"ticker": asset.ticker}
                )

        if not notification_sent:
            logger.error(
                "notification_dispatch_failed_all_channels",
                extra={"ticker": asset.ticker},
            )

        return NotificationPayload(
            ticker=asset.ticker,
            user_profile=user_profile,
            degraded_raw_data_only=degraded_raw_data_only,
            rendered_text=telegram_text,
            asset_projection=projection,
            notification_sent=notification_sent,
            sent_at=sent_at,
            message_id=message_id,
            channel=channel,
        )
