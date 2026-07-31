"""Tests de `GET/POST/DELETE /watchlist` — CRUD scoped al usuario autenticado; nunca se puede
leer ni borrar un item de otro usuario, aunque se conozca su UUID.
"""

from __future__ import annotations

import httpx


async def _register_and_login(client: httpx.AsyncClient, email: str) -> dict[str, str]:
    await client.post(
        "/api/v1/auth/register", json={"email": email, "password": "supersecreta1"}
    )
    login_response = await client.post(
        "/api/v1/auth/login", json={"email": email, "password": "supersecreta1"}
    )
    token = login_response.json()["access_token"]
    return {"Authorization": f"Bearer {token}"}


async def test_add_and_list_watchlist_item(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "watcher1@example.com")

    create_response = await client.post(
        "/api/v1/watchlist",
        json={"ticker": "nvda", "asset_type": "STOCK", "alert_threshold_pct": "5.0"},
        headers=headers,
    )
    assert create_response.status_code == 201
    created = create_response.json()
    assert created["ticker"] == "NVDA"  # se normaliza a mayúsculas
    assert created["asset_type"] == "STOCK"
    assert created["enable_beginner_mode"] is False

    list_response = await client.get("/api/v1/watchlist", headers=headers)
    assert list_response.status_code == 200
    items = list_response.json()
    assert len(items) == 1
    assert items[0]["ticker"] == "NVDA"


async def test_cannot_add_duplicate_ticker(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "watcher2@example.com")
    payload = {"ticker": "BTC-USD", "asset_type": "CRYPTO"}

    first = await client.post("/api/v1/watchlist", json=payload, headers=headers)
    second = await client.post("/api/v1/watchlist", json=payload, headers=headers)

    assert first.status_code == 201
    assert second.status_code == 409


async def test_update_watchlist_item(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "watcher-patch@example.com")
    created = (
        await client.post(
            "/api/v1/watchlist",
            json={"ticker": "MSFT", "asset_type": "STOCK"},
            headers=headers,
        )
    ).json()

    patch_response = await client.patch(
        f"/api/v1/watchlist/{created['id']}",
        json={"alert_threshold_pct": "7.5", "enable_beginner_mode": True},
        headers=headers,
    )
    assert patch_response.status_code == 200
    updated = patch_response.json()
    assert updated["alert_threshold_pct"] == "7.50"
    assert updated["enable_beginner_mode"] is True


async def test_update_watchlist_item_partial_leaves_other_field_untouched(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "watcher-patch2@example.com")
    created = (
        await client.post(
            "/api/v1/watchlist",
            json={
                "ticker": "GOOG",
                "asset_type": "STOCK",
                "alert_threshold_pct": "4.0",
                "enable_beginner_mode": True,
            },
            headers=headers,
        )
    ).json()

    patch_response = await client.patch(
        f"/api/v1/watchlist/{created['id']}",
        json={"alert_threshold_pct": "9.0"},
        headers=headers,
    )
    updated = patch_response.json()
    assert updated["alert_threshold_pct"] == "9.00"
    assert updated["enable_beginner_mode"] is True


async def test_cannot_update_another_users_watchlist_item(
    client: httpx.AsyncClient,
) -> None:
    owner_headers = await _register_and_login(client, "patchowner@example.com")
    other_headers = await _register_and_login(client, "patchintruder@example.com")

    created = (
        await client.post(
            "/api/v1/watchlist",
            json={"ticker": "AMZN", "asset_type": "STOCK"},
            headers=owner_headers,
        )
    ).json()

    patch_response = await client.patch(
        f"/api/v1/watchlist/{created['id']}",
        json={"enable_beginner_mode": True},
        headers=other_headers,
    )
    assert patch_response.status_code == 404


async def test_delete_watchlist_item(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "watcher3@example.com")
    created = (
        await client.post(
            "/api/v1/watchlist",
            json={"ticker": "AAPL", "asset_type": "STOCK"},
            headers=headers,
        )
    ).json()

    delete_response = await client.delete(
        f"/api/v1/watchlist/{created['id']}", headers=headers
    )
    assert delete_response.status_code == 204

    list_response = await client.get("/api/v1/watchlist", headers=headers)
    assert list_response.json() == []


async def test_cannot_delete_another_users_item(client: httpx.AsyncClient) -> None:
    owner_headers = await _register_and_login(client, "owner@example.com")
    other_headers = await _register_and_login(client, "intruder@example.com")

    created = (
        await client.post(
            "/api/v1/watchlist",
            json={"ticker": "TSLA", "asset_type": "STOCK"},
            headers=owner_headers,
        )
    ).json()

    delete_response = await client.delete(
        f"/api/v1/watchlist/{created['id']}", headers=other_headers
    )
    assert delete_response.status_code == 404

    owner_list = (await client.get("/api/v1/watchlist", headers=owner_headers)).json()
    assert len(owner_list) == 1


async def test_watchlist_isolated_between_users(client: httpx.AsyncClient) -> None:
    headers_a = await _register_and_login(client, "usera@example.com")
    headers_b = await _register_and_login(client, "userb@example.com")

    await client.post(
        "/api/v1/watchlist",
        json={"ticker": "MSFT", "asset_type": "STOCK"},
        headers=headers_a,
    )

    list_a = (await client.get("/api/v1/watchlist", headers=headers_a)).json()
    list_b = (await client.get("/api/v1/watchlist", headers=headers_b)).json()

    assert len(list_a) == 1
    assert len(list_b) == 0
