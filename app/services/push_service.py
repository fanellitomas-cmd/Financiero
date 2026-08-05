"""Toma el `PushNotificationPayload` del Nodo 5 (`src/notification/`) y lo entrega a los
usuarios que siguen ese ticker en su `Watchlist`. La entrega real combina tres canales:
FCM por tópico (broadcast a quien se suscribió a `alerts_{ticker}` sin login), FCM por
token (push personalizado a los `DeviceTokens` de los usuarios que SÍ siguen ese ticker en
su Watchlist) y WebSocket (broadcast a las conexiones activas suscriptas a ese ticker).
Todo reutilizando `src/notification/fcm_client.py` — el mismo cliente que ya usa el motor.

A quién le corresponde la alerta lo decide `app/services/watchlist_alert_service.py`: seguir el
ticker es condición necesaria, y las reglas contextuales que el usuario haya configurado
(`PRICE`/`NEWS_SEVERITY`/`TREND_BREAK`) son el filtro fino. Sin reglas configuradas, se recibe
todo — igual que antes de que existieran.
"""

from __future__ import annotations

import asyncio
import logging
from collections import defaultdict
from typing import Protocol

from pydantic import BaseModel, ConfigDict
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
from sqlalchemy.orm import selectinload

from app.models.device_token import DeviceToken
from app.models.watchlist import WatchlistItem
from app.services.watchlist_alert_service import (
    build_evaluation_context,
    select_eligible_items,
)
from src.notification.fcm_client import FCMClient
from src.validation.domain_models import (
    DataStatus,
    MarketAlert,
    PushNotificationPayload,
)

logger = logging.getLogger(__name__)


class BroadcastTarget(Protocol):
    """Lo mínimo que `TickerConnectionManager` necesita de una conexión — deliberadamente no
    es `starlette.websockets.WebSocket` para no acoplar este servicio a FastAPI/Starlette; un
    `WebSocket` real lo satisface estructuralmente (tiene `send_json`), y en tests alcanza con
    cualquier objeto con ese método, sin necesitar un WebSocket real ni `type: ignore`.
    """

    async def send_json(self, data: object) -> None: ...


class TickerConnectionManager:
    """Broadcast en tiempo real a los clientes suscriptos a un ticker (normalmente, conexiones
    WebSocket). Estado en memoria de un solo proceso — para múltiples réplicas del backend
    esto necesitaría un bus compartido (ej. Redis pub/sub), fuera de alcance de este esqueleto.
    """

    def __init__(self) -> None:
        self._subscribers: dict[str, set[BroadcastTarget]] = defaultdict(set)

    def subscribe(self, ticker: str, target: BroadcastTarget) -> None:
        self._subscribers[ticker.upper()].add(target)

    def unsubscribe(self, ticker: str, target: BroadcastTarget) -> None:
        self._subscribers[ticker.upper()].discard(target)

    def subscriber_count(self, ticker: str) -> int:
        return len(self._subscribers.get(ticker.upper(), set()))

    async def broadcast(self, ticker: str, message: dict[str, object]) -> int:
        connections = list(self._subscribers.get(ticker.upper(), set()))
        delivered = 0
        for target in connections:
            try:
                await target.send_json(message)
                delivered += 1
            except Exception as exc:  # noqa: BLE001 — una conexión rota no debe abortar el
                # broadcast al resto de suscriptores; se degrada (se descarta) y se registra.
                logger.warning(
                    "websocket_broadcast_failed",
                    extra={"ticker": ticker, "error": str(exc)},
                )
                self._subscribers[ticker.upper()].discard(target)
        return delivered


class WatcherDispatchResult(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ticker: str
    watcher_count: int
    beginner_preference_count: int
    fcm_dispatched: bool
    websocket_delivered_count: int
    device_push_delivered_count: int = 0

    # Cuántos de los que siguen el ticker quedaron afuera porque sus propias reglas contextuales
    # no matchearon. Se expone en el resultado y no solo en un log porque es la diferencia entre
    # "nadie sigue este ticker" y "lo siguen 40 personas y ninguna pidió que le avisen de esto" —
    # dos situaciones que sin este número se leen igual en las métricas de entrega.
    rule_suppressed_count: int = 0


class PushNotificationService:
    def __init__(
        self,
        session_factory: async_sessionmaker[AsyncSession],
        *,
        fcm_client: FCMClient | None = None,
        connection_manager: TickerConnectionManager | None = None,
    ) -> None:
        self._session_factory = session_factory
        self._fcm_client = fcm_client
        self._connection_manager = connection_manager

    async def dispatch_to_watchers(
        self,
        payload: PushNotificationPayload,
        *,
        market_alert: MarketAlert | None = None,
    ) -> WatcherDispatchResult:
        """Entrega la alerta a quienes siguen el ticker Y cuyas reglas contextuales la aceptan.

        `market_alert` es opcional y por keyword para no romper a los llamadores que solo tienen el
        payload. Cuando llega, aporta el disparador y su magnitud — que es lo único con lo que una
        regla `PRICE` puede decidir, porque el payload del Nodo 5 no lleva la variación que la
        originó. Sin ella, las reglas de precio no matchean y las contextuales sí: se degrada la
        precisión del filtro, no la entrega.
        """

        context = build_evaluation_context(
            payload,
            trigger_type=market_alert.trigger_type
            if market_alert is not None
            else None,
            trigger_value=market_alert.trigger_value
            if market_alert is not None
            else None,
        )

        async with self._session_factory() as session:
            items = list(
                (
                    await session.execute(
                        select(WatchlistItem)
                        .options(selectinload(WatchlistItem.alert_rules))
                        .where(WatchlistItem.ticker == payload.ticker)
                    )
                )
                .scalars()
                .all()
            )

            eligible_item_ids = select_eligible_items(
                ((item.id, item.alert_rules) for item in items), context
            )
            eligible_user_ids = {
                item.user_id for item in items if item.id in eligible_item_ids
            }

            device_tokens: list[tuple[str]] = []
            if eligible_user_ids:
                device_tokens = [
                    (token,)
                    for (token,) in (
                        await session.execute(
                            select(DeviceToken.fcm_token)
                            .where(DeviceToken.user_id.in_(eligible_user_ids))
                            .distinct()
                        )
                    ).all()
                ]

        watcher_count = len(items)
        eligible_count = len(eligible_item_ids)
        beginner_preference_count = sum(
            1
            for item in items
            if item.enable_beginner_mode and item.id in eligible_item_ids
        )

        if watcher_count and not eligible_count:
            logger.info(
                "push_service_all_watchers_filtered_by_rules",
                extra={"ticker": payload.ticker, "watcher_count": watcher_count},
            )

        # El tópico FCM y el broadcast por WebSocket son por ticker, no por usuario: sus
        # suscriptores no están identificados (alguien puede seguir `alerts_NVDA` sin siquiera
        # tener cuenta), así que las reglas no pueden filtrarlos individualmente. Se los condiciona
        # a que haya al menos un destinatario elegible — el canal que sí es personal, el push por
        # token, sigue estando filtrado uno por uno.
        fcm_dispatched = False
        if self._fcm_client is not None and eligible_count > 0:
            topic = f"alerts_{payload.ticker}"
            fcm_result = await self._fcm_client.send_to_topic(topic, payload)
            fcm_dispatched = fcm_result.status == DataStatus.OK
            if not fcm_dispatched:
                logger.warning(
                    "push_service_fcm_dispatch_failed", extra={"ticker": payload.ticker}
                )

        device_push_delivered_count = 0
        if self._fcm_client is not None and device_tokens:
            results = await asyncio.gather(
                *(
                    self._fcm_client.send_to_token(token, payload)
                    for (token,) in device_tokens
                )
            )
            device_push_delivered_count = sum(
                1 for result in results if result.status == DataStatus.OK
            )

        websocket_delivered_count = 0
        if self._connection_manager is not None and eligible_count > 0:
            websocket_delivered_count = await self._connection_manager.broadcast(
                payload.ticker, payload.model_dump(mode="json")
            )

        return WatcherDispatchResult(
            ticker=payload.ticker,
            watcher_count=watcher_count,
            beginner_preference_count=beginner_preference_count,
            fcm_dispatched=fcm_dispatched,
            websocket_delivered_count=websocket_delivered_count,
            device_push_delivered_count=device_push_delivered_count,
            rule_suppressed_count=watcher_count - eligible_count,
        )
