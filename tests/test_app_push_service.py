"""Tests de `PushNotificationService`/`TickerConnectionManager`: cuenta correctamente los
watchers de un ticker en la DB, despacha por FCM solo cuando corresponde, y hace broadcast a
las conexiones activas — sin red real y sin necesitar un WebSocket real.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from decimal import Decimal

import httpx
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.security import hash_password
from app.models.device_token import DeviceToken
from app.models.enums import AssetType, DevicePlatform
from app.models.user import User
from app.models.watchlist import WatchlistItem
from app.services.push_service import PushNotificationService, TickerConnectionManager
from src.notification.fcm_client import FCMClient
from src.validation.domain_models import (
    AlertSeverity,
    AnalysisNarrative,
    PushNotificationPayload,
)


def _make_payload(ticker: str = "NVDA") -> PushNotificationPayload:
    return PushNotificationPayload(
        notification_id=str(uuid.uuid4()),
        ticker=ticker,
        asset_type="stock",
        title="Alerta",
        short_summary="Resumen",
        technical_narrative=AnalysisNarrative(headline="Headline técnico"),
        beginner_narrative=AnalysisNarrative(headline="Headline simple"),
        default_view="technical",
        urgency_level=AlertSeverity.HIGH,
        action_url="financiero://asset/NVDA",
        timestamp=datetime.now(timezone.utc),
        push_dispatched=False,
        alert_db_id=None,
    )


async def _add_watcher(
    session_factory: async_sessionmaker[AsyncSession],
    ticker: str,
    *,
    beginner_mode: bool,
    fcm_token: str | None = None,
) -> None:
    async with session_factory() as session:
        user = User(
            email=f"{uuid.uuid4()}@example.com", hashed_password=hash_password("x")
        )
        session.add(user)
        await session.flush()
        session.add(
            WatchlistItem(
                user_id=user.id,
                ticker=ticker,
                asset_type=AssetType.STOCK,
                alert_threshold_pct=Decimal("3.0"),
                enable_beginner_mode=beginner_mode,
            )
        )
        if fcm_token is not None:
            session.add(
                DeviceToken(
                    user_id=user.id,
                    fcm_token=fcm_token,
                    platform=DevicePlatform.ANDROID,
                )
            )
        await session.commit()


async def test_dispatch_counts_watchers_and_beginner_preference(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _add_watcher(db_session_factory, "NVDA", beginner_mode=False)
    await _add_watcher(db_session_factory, "NVDA", beginner_mode=True)
    await _add_watcher(
        db_session_factory, "AAPL", beginner_mode=False
    )  # otro ticker, no cuenta

    service = PushNotificationService(db_session_factory)
    result = await service.dispatch_to_watchers(_make_payload("NVDA"))

    assert result.watcher_count == 2
    assert result.beginner_preference_count == 1
    assert result.fcm_dispatched is False  # sin FCM configurado


async def test_dispatch_uses_fcm_when_configured_and_there_are_watchers(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _add_watcher(db_session_factory, "NVDA", beginner_mode=False)

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"name": "projects/x/messages/1"})

    fcm = FCMClient(
        "proj",
        "token",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(handler),
            base_url="https://fcm.googleapis.com/v1",
        ),
    )
    service = PushNotificationService(db_session_factory, fcm_client=fcm)

    try:
        result = await service.dispatch_to_watchers(_make_payload("NVDA"))
        assert result.fcm_dispatched is True
    finally:
        await fcm.aclose()


async def test_dispatch_skips_fcm_when_no_watchers(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    call_count = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal call_count
        call_count += 1
        return httpx.Response(200, json={"name": "x"})

    fcm = FCMClient(
        "proj",
        "token",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(handler),
            base_url="https://fcm.googleapis.com/v1",
        ),
    )
    service = PushNotificationService(db_session_factory, fcm_client=fcm)

    try:
        result = await service.dispatch_to_watchers(_make_payload("GOOG"))
        assert result.watcher_count == 0
        assert result.fcm_dispatched is False
        assert call_count == 0
    finally:
        await fcm.aclose()


class _FakeConnection:
    def __init__(self) -> None:
        self.received: list[dict[str, object]] = []

    async def send_json(self, data: object) -> None:
        assert isinstance(data, dict)
        self.received.append(data)


class _BrokenConnection:
    async def send_json(self, data: object) -> None:
        raise RuntimeError("connection closed")


async def test_connection_manager_broadcasts_to_subscribers() -> None:
    manager = TickerConnectionManager()
    connection_1 = _FakeConnection()
    connection_2 = _FakeConnection()
    manager.subscribe("NVDA", connection_1)
    manager.subscribe("NVDA", connection_2)

    delivered = await manager.broadcast("nvda", {"hello": "world"})

    assert delivered == 2
    assert connection_1.received == [{"hello": "world"}]
    assert connection_2.received == [{"hello": "world"}]


async def test_connection_manager_drops_broken_connection() -> None:
    manager = TickerConnectionManager()
    manager.subscribe("NVDA", _BrokenConnection())

    delivered = await manager.broadcast("NVDA", {"x": 1})

    assert delivered == 0
    assert manager.subscriber_count("NVDA") == 0


async def test_dispatch_broadcasts_over_connection_manager(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _add_watcher(db_session_factory, "NVDA", beginner_mode=False)

    manager = TickerConnectionManager()
    connection = _FakeConnection()
    manager.subscribe("NVDA", connection)

    service = PushNotificationService(db_session_factory, connection_manager=manager)
    result = await service.dispatch_to_watchers(_make_payload("NVDA"))

    assert result.websocket_delivered_count == 1
    assert len(connection.received) == 1
    assert connection.received[0]["ticker"] == "NVDA"


async def test_dispatch_sends_personalized_push_to_registered_device_tokens(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _add_watcher(
        db_session_factory, "NVDA", beginner_mode=False, fcm_token="device-token-1"
    )
    await _add_watcher(
        db_session_factory, "NVDA", beginner_mode=True, fcm_token="device-token-2"
    )
    await _add_watcher(db_session_factory, "NVDA", beginner_mode=False)  # sin device

    sent_tokens: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        body = request.read()
        sent_tokens.append(body.decode())
        return httpx.Response(200, json={"name": "projects/x/messages/1"})

    fcm = FCMClient(
        "proj",
        "token",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(handler),
            base_url="https://fcm.googleapis.com/v1",
        ),
    )
    service = PushNotificationService(db_session_factory, fcm_client=fcm)

    try:
        result = await service.dispatch_to_watchers(_make_payload("NVDA"))
        assert result.device_push_delivered_count == 2
        assert any("device-token-1" in body for body in sent_tokens)
        assert any("device-token-2" in body for body in sent_tokens)
    finally:
        await fcm.aclose()
