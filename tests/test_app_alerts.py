"""Tests de `GET /api/v1/alerts` — Centro de Notificaciones: paginado y filtrado a los
tickers que el usuario autenticado sigue en su Watchlist, nunca el historial completo.
"""

from __future__ import annotations

from datetime import datetime, timezone

import httpx
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.alert_history import AlertHistory
from src.validation.domain_models import AlertSeverity


async def _register_and_login(client: httpx.AsyncClient, email: str) -> dict[str, str]:
    await client.post(
        "/api/v1/auth/register", json={"email": email, "password": "supersecreta1"}
    )
    login_response = await client.post(
        "/api/v1/auth/login", json={"email": email, "password": "supersecreta1"}
    )
    token = login_response.json()["access_token"]
    return {"Authorization": f"Bearer {token}"}


async def _insert_alert(
    session_factory: async_sessionmaker[AsyncSession],
    ticker: str,
    index: int,
    *,
    created_at: datetime | None = None,
) -> None:
    async with session_factory() as session:
        alert = AlertHistory(
            ticker=ticker,
            payload_json={"ticker": ticker, "index": index},
            urgency_level=AlertSeverity.MEDIUM,
        )
        # `created_at` tiene `server_default=func.now()`, que en SQLite solo tiene
        # granularidad de segundo — insertar varias alertas seguidas en un test podría
        # empatar el timestamp. Se fija explícito acá para que el orden por
        # `created_at DESC` sea determinístico, sin depender del reloj del test.
        if created_at is not None:
            alert.created_at = created_at
        session.add(alert)
        await session.commit()


async def test_list_alerts_filters_to_own_watchlist_tickers(
    client: httpx.AsyncClient,
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    headers = await _register_and_login(client, "alerts1@example.com")
    await client.post(
        "/api/v1/watchlist",
        json={"ticker": "NVDA", "asset_type": "STOCK"},
        headers=headers,
    )

    await _insert_alert(db_session_factory, "NVDA", 1)
    await _insert_alert(db_session_factory, "AAPL", 2)  # no seguido por este usuario

    response = await client.get("/api/v1/alerts", headers=headers)
    assert response.status_code == 200
    body = response.json()
    assert body["total"] == 1
    assert len(body["items"]) == 1
    assert body["items"][0]["ticker"] == "NVDA"


async def test_list_alerts_is_paginated_most_recent_first(
    client: httpx.AsyncClient,
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    headers = await _register_and_login(client, "alerts2@example.com")
    await client.post(
        "/api/v1/watchlist",
        json={"ticker": "TSLA", "asset_type": "STOCK"},
        headers=headers,
    )

    base_time = datetime(2026, 7, 31, 12, 0, tzinfo=timezone.utc)
    for index in range(3):
        await _insert_alert(
            db_session_factory,
            "TSLA",
            index,
            created_at=base_time.replace(minute=index),
        )

    response = await client.get(
        "/api/v1/alerts", params={"limit": 2, "offset": 0}, headers=headers
    )
    body = response.json()
    assert body["total"] == 3
    assert body["limit"] == 2
    assert len(body["items"]) == 2
    assert body["items"][0]["payload_json"]["index"] == 2  # el más reciente insertado


async def test_list_alerts_empty_when_no_watchlist(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "alerts3@example.com")

    response = await client.get("/api/v1/alerts", headers=headers)
    assert response.status_code == 200
    assert response.json() == {"items": [], "total": 0, "limit": 20, "offset": 0}


async def test_list_alerts_requires_auth(client: httpx.AsyncClient) -> None:
    response = await client.get("/api/v1/alerts")
    assert response.status_code == 401
