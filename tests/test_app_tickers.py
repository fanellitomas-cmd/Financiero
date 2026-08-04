"""Tests del catálogo de tickers: normalización MIC -> bolsa, sincronización paginada desde
Polygon (sin red real, `httpx.MockTransport`), y `GET /api/v1/tickers` con filtro por bolsa,
búsqueda y paginación.
"""

from __future__ import annotations

import httpx
import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.enums import ExchangeType
from app.models.ticker import Ticker
from app.services.ticker_catalog_service import (
    TickerCatalogService,
    normalize_exchange,
)
from src.ingestion.polygon_client import PolygonClient


def _polygon_client(handler: httpx.MockTransport) -> PolygonClient:
    return PolygonClient(
        "fake-key",
        http_client=httpx.AsyncClient(
            transport=handler, base_url="https://api.polygon.io"
        ),
    )


def _entry(
    symbol: str, name: str, mic: str | None, asset_type: str = "CS"
) -> dict[str, object]:
    return {
        "ticker": symbol,
        "name": name,
        "primary_exchange": mic,
        "type": asset_type,
        "active": True,
    }


async def _seed(
    session_factory: async_sessionmaker[AsyncSession], rows: list[Ticker]
) -> None:
    async with session_factory() as session:
        session.add_all(rows)
        await session.commit()


def _ticker(
    symbol: str,
    name: str,
    exchange: ExchangeType,
    *,
    active: bool = True,
    mic: str | None = None,
) -> Ticker:
    return Ticker(
        symbol=symbol,
        name=name,
        primary_exchange=mic,
        exchange=exchange,
        asset_type="CS",
        active=active,
    )


# --- normalización MIC -> bolsa -------------------------------------------------------------


def test_normalize_exchange_maps_known_mic_codes() -> None:
    assert normalize_exchange("XNAS") == ExchangeType.NASDAQ
    assert normalize_exchange("XNYS") == ExchangeType.NYSE


def test_normalize_exchange_is_case_insensitive() -> None:
    assert normalize_exchange("xnas") == ExchangeType.NASDAQ


@pytest.mark.parametrize("mic", ["ARCX", "XASE", "BATS", "DESCONOCIDO", None])
def test_normalize_exchange_falls_back_to_other(mic: str | None) -> None:
    """Las afiliadas del NYSE (Arca, American) y cualquier MIC desconocido caen en OTHER — no
    se adivina NYSE ni se descarta el ticker.
    """

    assert normalize_exchange(mic) == ExchangeType.OTHER


# --- sincronización desde Polygon -----------------------------------------------------------


async def test_sync_follows_pagination_and_persists_normalized_exchange(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(str(request.url))
        if "cursor=page2" in str(request.url):
            return httpx.Response(
                200, json={"results": [_entry("KO", "Coca-Cola", "XNYS")]}
            )
        return httpx.Response(
            200,
            json={
                "results": [
                    _entry("NVDA", "NVIDIA Corp", "XNAS"),
                    _entry("SPY", "SPDR S&P 500 ETF", "ARCX", asset_type="ETF"),
                ],
                "next_url": "https://api.polygon.io/v3/reference/tickers?cursor=page2",
            },
        )

    polygon = _polygon_client(httpx.MockTransport(handler))
    catalog = TickerCatalogService(db_session_factory)

    try:
        total = await catalog.sync_from_polygon(polygon, page_size=2)
    finally:
        await polygon.aclose()

    assert total == 3
    assert len(calls) == 2  # siguió el next_url

    async with db_session_factory() as session:
        rows = {
            row.symbol: row
            for row in (await session.execute(select(Ticker))).scalars().all()
        }

    assert rows["NVDA"].exchange == ExchangeType.NASDAQ
    assert rows["KO"].exchange == ExchangeType.NYSE
    assert rows["SPY"].exchange == ExchangeType.OTHER  # ARCX no es NYSE
    assert rows["SPY"].asset_type == "ETF"
    # El MIC crudo se conserva además de la forma normalizada.
    assert rows["NVDA"].primary_exchange == "XNAS"


async def test_sync_reinjects_api_key_on_paginated_requests(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """El `next_url` de Polygon no incluye la credencial — si no se reinyecta, el segundo salto
    devolvería 401 y la sincronización quedaría a mitad de camino.
    """

    seen_keys: list[str | None] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen_keys.append(request.url.params.get("apiKey"))
        if "cursor=page2" in str(request.url):
            return httpx.Response(
                200, json={"results": [_entry("KO", "Coca-Cola", "XNYS")]}
            )
        return httpx.Response(
            200,
            json={
                "results": [_entry("NVDA", "NVIDIA Corp", "XNAS")],
                "next_url": "https://api.polygon.io/v3/reference/tickers?cursor=page2",
            },
        )

    polygon = _polygon_client(httpx.MockTransport(handler))
    try:
        await TickerCatalogService(db_session_factory).sync_from_polygon(polygon)
    finally:
        await polygon.aclose()

    assert seen_keys == ["fake-key", "fake-key"]


async def test_sync_is_idempotent_and_updates_existing_rows(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """Correr la sincronización dos veces no duplica símbolos (upsert por la PK natural) y sí
    actualiza los campos que cambiaron.
    """

    name = {"value": "NVIDIA Corp"}

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200, json={"results": [_entry("NVDA", name["value"], "XNAS")]}
        )

    polygon = _polygon_client(httpx.MockTransport(handler))
    catalog = TickerCatalogService(db_session_factory)

    try:
        await catalog.sync_from_polygon(polygon)
        name["value"] = "NVIDIA Corporation"  # el proveedor cambia el nombre
        await catalog.sync_from_polygon(polygon)
    finally:
        await polygon.aclose()

    async with db_session_factory() as session:
        rows = (await session.execute(select(Ticker))).scalars().all()

    assert len(rows) == 1
    assert rows[0].name == "NVIDIA Corporation"


async def test_sync_skips_malformed_entries_without_aborting(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "results": [
                    {"name": "Sin símbolo"},  # falta `ticker`
                    _entry("NVDA", "NVIDIA Corp", "XNAS"),
                    "no soy un objeto",
                ]
            },
        )

    polygon = _polygon_client(httpx.MockTransport(handler))
    try:
        total = await TickerCatalogService(db_session_factory).sync_from_polygon(
            polygon
        )
    finally:
        await polygon.aclose()

    assert total == 1  # solo el válido, sin explotar por los otros dos


# --- GET /api/v1/tickers --------------------------------------------------------------------


async def _auth_headers(client: httpx.AsyncClient, email: str) -> dict[str, str]:
    await client.post(
        "/api/v1/auth/register", json={"email": email, "password": "supersecreta1"}
    )
    login = await client.post(
        "/api/v1/auth/login", json={"email": email, "password": "supersecreta1"}
    )
    return {"Authorization": f"Bearer {login.json()['access_token']}"}


async def test_list_tickers_filters_by_exchange(
    client: httpx.AsyncClient, db_session_factory: async_sessionmaker[AsyncSession]
) -> None:
    await _seed(
        db_session_factory,
        [
            _ticker("NVDA", "NVIDIA Corp", ExchangeType.NASDAQ),
            _ticker("AAPL", "Apple Inc", ExchangeType.NASDAQ),
            _ticker("KO", "Coca-Cola Co", ExchangeType.NYSE),
        ],
    )
    headers = await _auth_headers(client, "tickers1@example.com")

    response = await client.get(
        "/api/v1/tickers", params={"exchange": "NASDAQ"}, headers=headers
    )

    assert response.status_code == 200
    body = response.json()
    assert body["total"] == 2
    assert {item["symbol"] for item in body["items"]} == {"NVDA", "AAPL"}


async def test_list_tickers_searches_symbol_and_name(
    client: httpx.AsyncClient, db_session_factory: async_sessionmaker[AsyncSession]
) -> None:
    await _seed(
        db_session_factory,
        [
            _ticker("NVDA", "NVIDIA Corp", ExchangeType.NASDAQ),
            _ticker("KO", "Coca-Cola Co", ExchangeType.NYSE),
        ],
    )
    headers = await _auth_headers(client, "tickers2@example.com")

    by_symbol = await client.get(
        "/api/v1/tickers", params={"q": "nvd"}, headers=headers
    )
    by_name = await client.get("/api/v1/tickers", params={"q": "coca"}, headers=headers)

    assert [item["symbol"] for item in by_symbol.json()["items"]] == ["NVDA"]
    assert [item["symbol"] for item in by_name.json()["items"]] == ["KO"]


async def test_list_tickers_combines_search_with_exchange_filter(
    client: httpx.AsyncClient, db_session_factory: async_sessionmaker[AsyncSession]
) -> None:
    await _seed(
        db_session_factory,
        [
            _ticker("META", "Meta Platforms", ExchangeType.NASDAQ),
            _ticker("MET", "MetLife Inc", ExchangeType.NYSE),
        ],
    )
    headers = await _auth_headers(client, "tickers3@example.com")

    response = await client.get(
        "/api/v1/tickers", params={"q": "met", "exchange": "NYSE"}, headers=headers
    )

    assert [item["symbol"] for item in response.json()["items"]] == ["MET"]


async def test_list_tickers_paginates_ordered_by_symbol(
    client: httpx.AsyncClient, db_session_factory: async_sessionmaker[AsyncSession]
) -> None:
    await _seed(
        db_session_factory,
        [
            _ticker("AAPL", "Apple Inc", ExchangeType.NASDAQ),
            _ticker("MSFT", "Microsoft Corp", ExchangeType.NASDAQ),
            _ticker("NVDA", "NVIDIA Corp", ExchangeType.NASDAQ),
        ],
    )
    headers = await _auth_headers(client, "tickers4@example.com")

    first = await client.get(
        "/api/v1/tickers", params={"limit": 2, "offset": 0}, headers=headers
    )
    second = await client.get(
        "/api/v1/tickers", params={"limit": 2, "offset": 2}, headers=headers
    )

    assert first.json()["total"] == 3
    assert [item["symbol"] for item in first.json()["items"]] == ["AAPL", "MSFT"]
    assert [item["symbol"] for item in second.json()["items"]] == ["NVDA"]


async def test_list_tickers_excludes_inactive(
    client: httpx.AsyncClient, db_session_factory: async_sessionmaker[AsyncSession]
) -> None:
    await _seed(
        db_session_factory,
        [
            _ticker("NVDA", "NVIDIA Corp", ExchangeType.NASDAQ),
            _ticker("DEAD", "Delistada SA", ExchangeType.NASDAQ, active=False),
        ],
    )
    headers = await _auth_headers(client, "tickers5@example.com")

    response = await client.get("/api/v1/tickers", headers=headers)

    assert [item["symbol"] for item in response.json()["items"]] == ["NVDA"]


async def test_list_tickers_rejects_unknown_exchange(
    client: httpx.AsyncClient,
) -> None:
    headers = await _auth_headers(client, "tickers6@example.com")

    response = await client.get(
        "/api/v1/tickers", params={"exchange": "BOLSA_INVENTADA"}, headers=headers
    )

    assert response.status_code == 422


async def test_list_tickers_requires_auth(client: httpx.AsyncClient) -> None:
    assert (await client.get("/api/v1/tickers")).status_code == 401
