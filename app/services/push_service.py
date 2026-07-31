"""Toma el `PushNotificationPayload` del Nodo 5 (`src/notification/`) y lo entrega a los
usuarios que siguen ese ticker en su `Watchlist`. La entrega real usa FCM (broadcast por
tópico, reutilizando `src/notification/fcm_client.py` — el mismo cliente que ya usa el motor)
y/o WebSocket (broadcast a las conexiones activas suscriptas a ese ticker).

No hay tabla de device tokens en este esquema todavía, así que no hay fan-out por token
individual por usuario — eso queda para cuando se agregue esa tabla. Por ahora, la consulta a
`Watchlists` determina CUÁNTOS usuarios están interesados (para `AlertHistory`/métricas) y su
preferencia agregada de `enable_beginner_mode`; la entrega en sí es por tópico/broadcast.
"""

from __future__ import annotations

import logging
from collections import defaultdict
from typing import Protocol

from pydantic import BaseModel, ConfigDict
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.watchlist import WatchlistItem
from src.notification.fcm_client import FCMClient
from src.validation.domain_models import DataStatus, PushNotificationPayload

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
        self, payload: PushNotificationPayload
    ) -> WatcherDispatchResult:
        async with self._session_factory() as session:
            rows = (
                await session.execute(
                    select(WatchlistItem.enable_beginner_mode).where(
                        WatchlistItem.ticker == payload.ticker
                    )
                )
            ).all()

        watcher_count = len(rows)
        beginner_preference_count = sum(1 for (is_beginner,) in rows if is_beginner)

        fcm_dispatched = False
        if self._fcm_client is not None and watcher_count > 0:
            topic = f"alerts_{payload.ticker}"
            fcm_result = await self._fcm_client.send_to_topic(topic, payload)
            fcm_dispatched = fcm_result.status == DataStatus.OK
            if not fcm_dispatched:
                logger.warning(
                    "push_service_fcm_dispatch_failed", extra={"ticker": payload.ticker}
                )

        websocket_delivered_count = 0
        if self._connection_manager is not None and watcher_count > 0:
            websocket_delivered_count = await self._connection_manager.broadcast(
                payload.ticker, payload.model_dump(mode="json")
            )

        return WatcherDispatchResult(
            ticker=payload.ticker,
            watcher_count=watcher_count,
            beginner_preference_count=beginner_preference_count,
            fcm_dispatched=fcm_dispatched,
            websocket_delivered_count=websocket_delivered_count,
        )
