"""Tests de `PolygonClient.get_daily_ohlc`, `MarketDataService.get_history` y
`GET /api/v1/market/history/{ticker}`.

El contrato que importa acá es que el chart NUNCA rompe la pantalla: cualquier fallo del proveedor
se traduce a `bars: []` con un motivo legible y HTTP 200. Un 500 o un 503 en este endpoint haría
que un histórico ausente se viera como una Ficha caída.
"""

from __future__ import annotations

from datetime import date

import httpx

from app.services.market_data_service import MarketDataService
from src.ingestion.polygon_client import PolygonClient

_START = date(2026, 7, 5)
_END = date(2026, 8, 4)


def _polygon_client(transport: httpx.MockTransport) -> PolygonClient:
    return PolygonClient(
        "fake-key",
        http_client=httpx.AsyncClient(
            transport=transport, base_url="https://api.polygon.io"
        ),
    )


def _bar(
    timestamp_ms: int,
    *,
    open_: float = 100.0,
    high: float = 105.0,
    low: float = 98.0,
    close: float = 103.0,
    volume: float = 1_000_000.0,
) -> dict[str, object]:
    return {
        "t": timestamp_ms,
        "o": open_,
        "h": high,
        "l": low,
        "c": close,
        "v": volume,
    }


def _aggs_transport(
    bars: list[dict[str, object]],
    *,
    calls: list[httpx.Request] | None = None,
) -> httpx.MockTransport:
    def handler(request: httpx.Request) -> httpx.Response:
        if calls is not None:
            calls.append(request)
        return httpx.Response(
            200,
            json={
                "ticker": "NVDA",
                "resultsCount": len(bars),
                "status": "OK",
                "results": bars,
            },
        )

    return httpx.MockTransport(handler)


# --- PolygonClient.get_daily_ohlc ---------------------------------------------------------


async def test_get_daily_ohlc_parses_bars() -> None:
    polygon = _polygon_client(_aggs_transport([_bar(1_760_000_000_000)]))
    try:
        bars = await polygon.get_daily_ohlc("NVDA", start=_START, end=_END)
    finally:
        await polygon.aclose()

    assert len(bars) == 1
    bar = bars[0]
    assert bar.timestamp_ms == 1_760_000_000_000
    assert float(bar.open) == 100.0
    assert float(bar.high) == 105.0
    assert float(bar.low) == 98.0
    assert float(bar.close) == 103.0
    assert float(bar.volume) == 1_000_000.0


async def test_get_daily_ohlc_builds_the_expected_request() -> None:
    calls: list[httpx.Request] = []
    polygon = _polygon_client(_aggs_transport([], calls=calls))
    try:
        await polygon.get_daily_ohlc("nvda", start=_START, end=_END)
    finally:
        await polygon.aclose()

    assert len(calls) == 1
    url = calls[0].url
    # El rango va EN EL PATH, no en query params — así lo define el endpoint de agregados.
    assert url.path == "/v2/aggs/ticker/nvda/range/1/day/2026-07-05/2026-08-04"
    # `adjusted=true` es lo que evita que un split 10:1 se dibuje como una caída del 90%.
    assert url.params["adjusted"] == "true"
    assert url.params["sort"] == "asc"


async def test_get_daily_ohlc_sorts_bars_chronologically() -> None:
    # No se confía en `sort=asc`: el contrato del proveedor no se pudo verificar en vivo y un
    # chart con las velas desordenadas dibuja un garabato.
    polygon = _polygon_client(
        _aggs_transport(
            [_bar(3_000), _bar(1_000), _bar(2_000)],
        )
    )
    try:
        bars = await polygon.get_daily_ohlc("NVDA", start=_START, end=_END)
    finally:
        await polygon.aclose()

    assert [bar.timestamp_ms for bar in bars] == [1_000, 2_000, 3_000]


async def test_get_daily_ohlc_discards_incomplete_bars() -> None:
    """Una vela sin `h` o sin `c` no se puede dibujar. Rellenar con 0 dibujaría una mecha falsa que
    se lee como un movimiento real; descartarla deja un salto honesto en el eje.
    """

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "results": [
                    _bar(1_000),
                    {"t": 2_000, "o": 10.0, "h": 12.0},  # falta l/c/v
                    {"o": 10.0, "h": 12.0, "l": 9.0, "c": 11.0, "v": 5.0},  # falta t
                    _bar(3_000),
                ]
            },
        )

    polygon = _polygon_client(httpx.MockTransport(handler))
    try:
        bars = await polygon.get_daily_ohlc("NVDA", start=_START, end=_END)
    finally:
        await polygon.aclose()

    assert [bar.timestamp_ms for bar in bars] == [1_000, 3_000]


async def test_get_daily_ohlc_degrades_to_empty_on_provider_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, json={"error": "boom"})

    polygon = _polygon_client(httpx.MockTransport(handler))
    try:
        # Lista vacía y no excepción: el chart tiene que poder decir "sin histórico".
        assert await polygon.get_daily_ohlc("NVDA", start=_START, end=_END) == []
    finally:
        await polygon.aclose()


async def test_get_daily_ohlc_treats_missing_results_as_empty_history() -> None:
    # `resultsCount: 0` sin `results` es la respuesta normal para un rango sin ruedas: no es un
    # error del proveedor.
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"ticker": "NVDA", "resultsCount": 0})

    polygon = _polygon_client(httpx.MockTransport(handler))
    try:
        assert await polygon.get_daily_ohlc("NVDA", start=_START, end=_END) == []
    finally:
        await polygon.aclose()


async def test_get_daily_ohlc_degrades_on_invalid_json() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"no soy json")

    polygon = _polygon_client(httpx.MockTransport(handler))
    try:
        assert await polygon.get_daily_ohlc("NVDA", start=_START, end=_END) == []
    finally:
        await polygon.aclose()


# --- MarketDataService.get_history --------------------------------------------------------


async def test_get_history_maps_bars_to_the_chart_format() -> None:
    polygon = _polygon_client(_aggs_transport([_bar(1_760_000_000_000)]))
    service = MarketDataService(polygon)
    try:
        history = await service.get_history("nvda", start=_START, end=_END)
    finally:
        await polygon.aclose()

    # El ticker se normaliza a mayúsculas en la respuesta.
    assert history.ticker == "NVDA"
    assert history.start == _START
    assert history.end == _END
    assert history.degradation_reason is None

    bar = history.bars[0]
    assert bar.t == 1_760_000_000_000
    assert bar.o == 100.0
    assert bar.h == 105.0
    assert bar.l == 98.0
    assert bar.c == 103.0
    assert bar.v == 1_000_000.0


async def test_get_history_explains_an_empty_history() -> None:
    polygon = _polygon_client(_aggs_transport([]))
    service = MarketDataService(polygon)
    try:
        history = await service.get_history("NVDA", start=_START, end=_END)
    finally:
        await polygon.aclose()

    assert history.bars == []
    # El motivo no puede quedar en None: sin él el cliente no sabe si el mercado estuvo cerrado o
    # si falta la credencial.
    assert history.degradation_reason is not None
    assert "POLYGON_API_KEY" in history.degradation_reason


async def test_get_history_never_raises_on_provider_failure() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(503, json={"error": "down"})

    polygon = _polygon_client(httpx.MockTransport(handler))
    service = MarketDataService(polygon)
    try:
        history = await service.get_history("NVDA", start=_START, end=_END)
    finally:
        await polygon.aclose()

    assert history.bars == []
    assert history.degradation_reason is not None


# --- Endpoint -----------------------------------------------------------------------------


async def _auth_headers(client: httpx.AsyncClient, email: str) -> dict[str, str]:
    await client.post(
        "/api/v1/auth/register",
        json={"email": email, "password": "supersecreta1"},
    )
    login = await client.post(
        "/api/v1/auth/login",
        json={"email": email, "password": "supersecreta1"},
    )
    return {"Authorization": f"Bearer {login.json()['access_token']}"}


async def test_history_endpoint_requires_auth(client: httpx.AsyncClient) -> None:
    response = await client.get("/api/v1/market/history/NVDA")
    assert response.status_code == 401


async def test_history_endpoint_returns_bars(
    client: httpx.AsyncClient,
) -> None:
    from app.main import app

    polygon = _polygon_client(_aggs_transport([_bar(1_000), _bar(2_000)]))
    app.state.market_data_service = MarketDataService(polygon)

    try:
        headers = await _auth_headers(client, "history-ok@example.com")
        response = await client.get("/api/v1/market/history/NVDA", headers=headers)
    finally:
        app.state.market_data_service = None
        await polygon.aclose()

    assert response.status_code == 200
    body = response.json()
    assert body["ticker"] == "NVDA"
    assert [bar["t"] for bar in body["bars"]] == [1_000, 2_000]
    # La clave se serializa como `l`, la que espera una librería de charting.
    assert set(body["bars"][0]) == {"t", "o", "h", "l", "c", "v"}
    assert body["degradation_reason"] is None


async def test_history_endpoint_defaults_to_thirty_days(
    client: httpx.AsyncClient,
) -> None:
    from app.main import app

    calls: list[httpx.Request] = []
    polygon = _polygon_client(_aggs_transport([], calls=calls))
    app.state.market_data_service = MarketDataService(polygon)

    try:
        headers = await _auth_headers(client, "history-default@example.com")
        response = await client.get("/api/v1/market/history/NVDA", headers=headers)
    finally:
        app.state.market_data_service = None
        await polygon.aclose()

    assert response.status_code == 200
    body = response.json()
    assert (
        date.fromisoformat(body["end"]) - date.fromisoformat(body["start"])
    ).days == 30
    # El rango del pedido al proveedor coincide con el que se le informa al cliente.
    assert body["start"] in str(calls[0].url.path)
    assert body["end"] in str(calls[0].url.path)


async def test_history_endpoint_accepts_an_explicit_range(
    client: httpx.AsyncClient,
) -> None:
    from app.main import app

    polygon = _polygon_client(_aggs_transport([_bar(1_000)]))
    app.state.market_data_service = MarketDataService(polygon)

    try:
        headers = await _auth_headers(client, "history-range@example.com")
        response = await client.get(
            "/api/v1/market/history/NVDA?start=2026-01-01&end=2026-03-01",
            headers=headers,
        )
    finally:
        app.state.market_data_service = None
        await polygon.aclose()

    assert response.status_code == 200
    body = response.json()
    assert body["start"] == "2026-01-01"
    assert body["end"] == "2026-03-01"


async def test_history_endpoint_rejects_a_half_specified_range(
    client: httpx.AsyncClient,
) -> None:
    from app.main import app

    polygon = _polygon_client(_aggs_transport([]))
    app.state.market_data_service = MarketDataService(polygon)

    try:
        headers = await _auth_headers(client, "history-half@example.com")
        # Con solo `start`, el servidor tendría que inventar el otro extremo: mejor un 422.
        response = await client.get(
            "/api/v1/market/history/NVDA?start=2026-01-01", headers=headers
        )
    finally:
        app.state.market_data_service = None
        await polygon.aclose()

    assert response.status_code == 422


async def test_history_endpoint_rejects_an_inverted_range(
    client: httpx.AsyncClient,
) -> None:
    from app.main import app

    polygon = _polygon_client(_aggs_transport([]))
    app.state.market_data_service = MarketDataService(polygon)

    try:
        headers = await _auth_headers(client, "history-inverted@example.com")
        response = await client.get(
            "/api/v1/market/history/NVDA?start=2026-03-01&end=2026-01-01",
            headers=headers,
        )
    finally:
        app.state.market_data_service = None
        await polygon.aclose()

    assert response.status_code == 422


async def test_history_endpoint_returns_200_with_empty_bars_when_provider_fails(
    client: httpx.AsyncClient,
) -> None:
    """El contrato central del endpoint: un proveedor caído es 200 + `bars: []` + motivo, NO un
    5xx. Un error HTTP acá haría que un histórico ausente se viera como una Ficha caída.
    """

    from app.main import app

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, json={"error": "boom"})

    polygon = _polygon_client(httpx.MockTransport(handler))
    app.state.market_data_service = MarketDataService(polygon)

    try:
        headers = await _auth_headers(client, "history-down@example.com")
        response = await client.get("/api/v1/market/history/NVDA", headers=headers)
    finally:
        app.state.market_data_service = None
        await polygon.aclose()

    assert response.status_code == 200
    body = response.json()
    assert body["bars"] == []
    assert body["degradation_reason"] is not None


async def test_history_endpoint_returns_503_when_polygon_is_not_configured(
    client: httpx.AsyncClient,
) -> None:
    """Sin `POLYGON_API_KEY` el servicio no se construye en el lifespan y la dependencia corta con
    503 antes de llegar al handler — mismo comportamiento que `/market/quotes`. Es distinto de "el
    proveedor falló", que sí es 200 con bars vacío.
    """

    headers = await _auth_headers(client, "history-503@example.com")
    response = await client.get("/api/v1/market/history/NVDA", headers=headers)

    assert response.status_code == 503
    assert "POLYGON_API_KEY" in response.json()["detail"]
