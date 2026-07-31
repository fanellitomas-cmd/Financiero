"""Tests de `GET/POST/DELETE /devices` — registro de FCM tokens por dispositivo, scoped al
usuario autenticado igual que `/watchlist`.
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


async def test_register_and_list_device_token(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "device1@example.com")

    create_response = await client.post(
        "/api/v1/devices",
        json={"fcm_token": "token-abc", "platform": "ANDROID"},
        headers=headers,
    )
    assert create_response.status_code == 201
    created = create_response.json()
    assert created["fcm_token"] == "token-abc"
    assert created["platform"] == "ANDROID"

    list_response = await client.get("/api/v1/devices", headers=headers)
    assert list_response.status_code == 200
    assert len(list_response.json()) == 1


async def test_registering_same_token_reassigns_to_new_owner(
    client: httpx.AsyncClient,
) -> None:
    headers_a = await _register_and_login(client, "devicea@example.com")
    headers_b = await _register_and_login(client, "deviceb@example.com")

    await client.post(
        "/api/v1/devices",
        json={"fcm_token": "shared-token", "platform": "IOS"},
        headers=headers_a,
    )
    await client.post(
        "/api/v1/devices",
        json={"fcm_token": "shared-token", "platform": "IOS"},
        headers=headers_b,
    )

    list_a = (await client.get("/api/v1/devices", headers=headers_a)).json()
    list_b = (await client.get("/api/v1/devices", headers=headers_b)).json()
    assert list_a == []
    assert len(list_b) == 1


async def test_delete_device_token(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "device2@example.com")
    created = (
        await client.post(
            "/api/v1/devices",
            json={"fcm_token": "token-xyz", "platform": "WEB"},
            headers=headers,
        )
    ).json()

    delete_response = await client.delete(
        f"/api/v1/devices/{created['id']}", headers=headers
    )
    assert delete_response.status_code == 204
    assert (await client.get("/api/v1/devices", headers=headers)).json() == []


async def test_cannot_delete_another_users_device_token(
    client: httpx.AsyncClient,
) -> None:
    owner_headers = await _register_and_login(client, "deviceowner@example.com")
    other_headers = await _register_and_login(client, "deviceintruder@example.com")

    created = (
        await client.post(
            "/api/v1/devices",
            json={"fcm_token": "token-owner", "platform": "IOS"},
            headers=owner_headers,
        )
    ).json()

    delete_response = await client.delete(
        f"/api/v1/devices/{created['id']}", headers=other_headers
    )
    assert delete_response.status_code == 404
