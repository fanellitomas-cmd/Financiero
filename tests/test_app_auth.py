"""Tests de `POST /auth/register` y `POST /auth/login` — registro, login, y que las rutas
protegidas por JWT (acá: `GET /watchlist`) rechacen tokens ausentes/inválidos.
"""

from __future__ import annotations

import httpx


async def test_register_creates_user(client: httpx.AsyncClient) -> None:
    response = await client.post(
        "/api/v1/auth/register",
        json={"email": "ana@example.com", "password": "supersecreta1"},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["email"] == "ana@example.com"
    assert body["plan_type"] == "FREE"
    assert "hashed_password" not in body


async def test_register_duplicate_email_returns_409(client: httpx.AsyncClient) -> None:
    payload = {"email": "dup@example.com", "password": "supersecreta1"}
    first = await client.post("/api/v1/auth/register", json=payload)
    second = await client.post("/api/v1/auth/register", json=payload)

    assert first.status_code == 201
    assert second.status_code == 409


async def test_login_with_correct_credentials_returns_token(
    client: httpx.AsyncClient,
) -> None:
    await client.post(
        "/api/v1/auth/register",
        json={"email": "login@example.com", "password": "supersecreta1"},
    )

    response = await client.post(
        "/api/v1/auth/login",
        json={"email": "login@example.com", "password": "supersecreta1"},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["token_type"] == "bearer"
    assert isinstance(body["access_token"], str) and body["access_token"]


async def test_login_with_wrong_password_returns_401(client: httpx.AsyncClient) -> None:
    await client.post(
        "/api/v1/auth/register",
        json={"email": "wrong@example.com", "password": "supersecreta1"},
    )

    response = await client.post(
        "/api/v1/auth/login",
        json={"email": "wrong@example.com", "password": "otra-cosa"},
    )

    assert response.status_code == 401


async def test_login_with_unknown_email_returns_401(client: httpx.AsyncClient) -> None:
    response = await client.post(
        "/api/v1/auth/login",
        json={"email": "no-existe@example.com", "password": "cualquiera1"},
    )

    assert response.status_code == 401


async def test_protected_route_without_token_returns_401(
    client: httpx.AsyncClient,
) -> None:
    response = await client.get("/api/v1/watchlist")

    assert response.status_code == 401


async def test_protected_route_with_invalid_token_returns_401(
    client: httpx.AsyncClient,
) -> None:
    response = await client.get(
        "/api/v1/watchlist", headers={"Authorization": "Bearer no-soy-un-jwt-valido"}
    )

    assert response.status_code == 401
