"""Tests de `MarketDataService` y `GET /api/v1/market/quotes`: precio y %var en vivo de la
Watchlist del usuario, degradando por-ticker (no todo el heatmap) si un proveedor falla.
"""

from __future__ import annotations

import httpx

from app.models.enums import AssetType
from app.services.market_data_service import MarketDataService
from src.ingestion.polygon_client import PolygonClient
from src.validation.domain_models import DataStatus


def _polygon_client(handler: httpx.MockTransport) -> PolygonClient:
    return PolygonClient(
        "fake-key",
        http_client=httpx.AsyncClient(
            transport=handler, base_url="https://api.polygon.io"
        ),
    )


def _equity_response(close: float, prev_close: float) -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "ticker": {
                "day": {"c": close, "o": prev_close, "h": close, "l": prev_close},
                "prevDay": {"c": prev_close},
                "todaysChangePerc": (close - prev_close) / prev_close * 100,
            }
        },
    )


async def test_get_quotes_returns_price_and_change_pct() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return _equity_response(110.0, 100.0)

    polygon = _polygon_client(httpx.MockTransport(handler))
    service = MarketDataService(polygon)

    try:
        quotes = await service.get_quotes([("NVDA", AssetType.STOCK)])
        assert len(quotes) == 1
        assert quotes[0].ticker == "NVDA"
        assert quotes[0].last_price == 110.0
        assert quotes[0].status == DataStatus.OK
    finally:
        await polygon.aclose()


async def test_get_quotes_degrades_single_ticker_on_provider_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if "AAPL" in request.url.path or "aapl" in request.url.path.lower():
            return httpx.Response(500, json={"error": "boom"})
        return _equity_response(50.0, 45.0)

    polygon = _polygon_client(httpx.MockTransport(handler))
    service = MarketDataService(polygon)

    try:
        quotes = await service.get_quotes(
            [("AAPL", AssetType.STOCK), ("MSFT", AssetType.STOCK)]
        )
    finally:
        await polygon.aclose()

    by_ticker = {quote.ticker: quote for quote in quotes}
    assert by_ticker["AAPL"].status == DataStatus.ERROR_API
    assert by_ticker["AAPL"].last_price is None
    assert by_ticker["MSFT"].status == DataStatus.OK
    assert by_ticker["MSFT"].last_price == 50.0


async def test_market_quotes_endpoint_returns_503_when_not_configured(
    client: httpx.AsyncClient,
) -> None:
    await client.post(
        "/api/v1/auth/register",
        json={"email": "market-user@example.com", "password": "supersecreta1"},
    )
    login = await client.post(
        "/api/v1/auth/login",
        json={"email": "market-user@example.com", "password": "supersecreta1"},
    )
    headers = {"Authorization": f"Bearer {login.json()['access_token']}"}

    response = await client.get("/api/v1/market/quotes", headers=headers)
    assert response.status_code == 503


async def test_market_quotes_endpoint_requires_auth(client: httpx.AsyncClient) -> None:
    response = await client.get("/api/v1/market/quotes")
    assert response.status_code == 401
