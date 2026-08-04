"""Tests de `MarketSummaryService` y `GET /api/v1/market/summary`.

Cubren las tres cosas que el endpoint promete y que son fáciles de romper sin darse cuenta:
  1. Los movers se cruzan con el catálogo local y se filtran a NASDAQ/NYSE.
  2. La caché evita llamadas repetidas a Gemini (contando invocaciones reales al transporte).
  3. Cada degradación (sin datos, sin Gemini, Gemini fallando, salida inválida) devuelve los
     datos duros que sí tiene y lo declara explícitamente, en vez de inventar una narrativa.
"""

from __future__ import annotations

import asyncio
import json

import httpx
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.enums import ExchangeType
from app.models.ticker import Ticker
from app.services.market_summary_service import MarketSummaryService
from src.ingestion.gemini_client import GeminiClient
from src.ingestion.polygon_client import MoverDirection, PolygonClient

_SYSTEM_PROMPT = "Sos un redactor de prueba. Devolvé el JSON pedido."


def _polygon_client(transport: httpx.MockTransport) -> PolygonClient:
    return PolygonClient(
        "fake-key",
        http_client=httpx.AsyncClient(
            transport=transport, base_url="https://api.polygon.io"
        ),
    )


def _gemini_client(transport: httpx.MockTransport) -> GeminiClient:
    return GeminiClient(
        "fake-key",
        http_client=httpx.AsyncClient(
            transport=transport,
            base_url="https://generativelanguage.googleapis.com/v1beta",
        ),
    )


def _movers_payload(entries: list[tuple[str, float, float]]) -> dict[str, object]:
    return {
        "tickers": [
            {"ticker": ticker, "todaysChangePerc": change, "day": {"c": close}}
            for ticker, change, close in entries
        ]
    }


def _polygon_transport(
    gainers: list[tuple[str, float, float]],
    losers: list[tuple[str, float, float]],
) -> httpx.MockTransport:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/gainers"):
            return httpx.Response(200, json=_movers_payload(gainers))
        if request.url.path.endswith("/losers"):
            return httpx.Response(200, json=_movers_payload(losers))
        return httpx.Response(404, json={"error": "not found"})

    return httpx.MockTransport(handler)


def _gemini_transport(
    calls: list[httpx.Request] | None = None,
    *,
    headline: str = "Jornada mixta en Nasdaq.",
    key_points: list[str] | None = None,
    sentiment: str = "NEUTRAL",
) -> httpx.MockTransport:
    body = {
        "headline": headline,
        "key_points": key_points if key_points is not None else ["Punto uno."],
        "sentiment_label": sentiment,
        "sentiment_confidence_pct": 61.0,
    }

    def handler(request: httpx.Request) -> httpx.Response:
        if calls is not None:
            calls.append(request)
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "finishReason": "STOP",
                        "content": {"parts": [{"text": json.dumps(body)}]},
                    }
                ]
            },
        )

    return httpx.MockTransport(handler)


async def _seed_catalog(
    session_factory: async_sessionmaker[AsyncSession],
    rows: list[tuple[str, str, ExchangeType]],
) -> None:
    async with session_factory() as session:
        for symbol, name, exchange in rows:
            session.add(
                Ticker(
                    symbol=symbol,
                    name=name,
                    primary_exchange="XNAS"
                    if exchange == ExchangeType.NASDAQ
                    else "XNYS",
                    exchange=exchange,
                    asset_type="CS",
                    active=True,
                )
            )
        await session.commit()


# --- Polygon: parseo de movers -----------------------------------------------------------


async def test_get_market_movers_parses_tickers() -> None:
    polygon = _polygon_client(_polygon_transport([("NVDA", 7.2, 950.0)], []))
    try:
        movers = await polygon.get_market_movers(MoverDirection.GAINERS)
    finally:
        await polygon.aclose()

    assert len(movers) == 1
    assert movers[0].ticker == "NVDA"
    assert movers[0].day_change_pct.value is not None
    assert float(movers[0].day_change_pct.value) == 7.2
    assert movers[0].last_price.value is not None
    assert float(movers[0].last_price.value) == 950.0


async def test_get_market_movers_degrades_to_empty_on_provider_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, json={"error": "boom"})

    polygon = _polygon_client(httpx.MockTransport(handler))
    try:
        # Lista vacía y no excepción: el resumen tiene que poder decir "no hay datos de alzas".
        assert await polygon.get_market_movers(MoverDirection.GAINERS) == []
    finally:
        await polygon.aclose()


async def test_get_market_movers_skips_entries_without_ticker() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "tickers": [
                    {"todaysChangePerc": 3.0, "day": {"c": 10.0}},  # sin ticker
                    {"ticker": "AAPL", "todaysChangePerc": 2.0, "day": {"c": 200.0}},
                ]
            },
        )

    polygon = _polygon_client(httpx.MockTransport(handler))
    try:
        movers = await polygon.get_market_movers(MoverDirection.LOSERS)
    finally:
        await polygon.aclose()

    assert [mover.ticker for mover in movers] == ["AAPL"]


# --- Servicio: enriquecido, filtro y narrativa --------------------------------------------


async def test_summary_filters_movers_to_offered_exchanges(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(
        db_session_factory,
        [
            ("NVDA", "NVIDIA Corporation", ExchangeType.NASDAQ),
            ("JPM", "JPMorgan Chase & Co.", ExchangeType.NYSE),
            # `OTHER` está en el catálogo pero la app no ofrece esa bolsa.
            ("ARCX1", "Fondo de otra bolsa", ExchangeType.OTHER),
        ],
    )

    polygon = _polygon_client(
        _polygon_transport(
            gainers=[
                ("NVDA", 7.2, 950.0),
                ("ARCX1", 12.0, 30.0),
                # No está en el catálogo: no se puede afirmar su bolsa, así que se descarta.
                ("DESCONOCIDO", 20.0, 5.0),
            ],
            losers=[("JPM", -3.1, 190.0)],
        )
    )
    gemini = _gemini_client(_gemini_transport())
    service = MarketSummaryService(
        polygon,
        db_session_factory,
        gemini_client=gemini,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        summary = await service.get_summary()
    finally:
        await polygon.aclose()
        await gemini.aclose()

    assert [mover.ticker for mover in summary.top_gainers] == ["NVDA"]
    assert [mover.ticker for mover in summary.top_losers] == ["JPM"]
    # El nombre y la bolsa salen del catálogo local, no del proveedor de movers.
    assert summary.top_gainers[0].name == "NVIDIA Corporation"
    assert summary.top_gainers[0].exchange == ExchangeType.NASDAQ
    assert summary.top_losers[0].exchange == ExchangeType.NYSE
    assert summary.market_data_available is True
    assert summary.ai_narrative_available is True
    assert summary.headline == "Jornada mixta en Nasdaq."
    assert summary.sentiment is not None
    assert summary.sentiment.label == "NEUTRAL"
    assert summary.degradation_reason is None


async def test_summary_respects_movers_per_direction_limit(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(
        db_session_factory,
        [(f"SYM{i}", f"Empresa {i}", ExchangeType.NASDAQ) for i in range(6)],
    )

    polygon = _polygon_client(
        _polygon_transport(
            gainers=[(f"SYM{i}", float(10 - i), 100.0) for i in range(6)],
            losers=[],
        )
    )
    gemini = _gemini_client(_gemini_transport())
    service = MarketSummaryService(
        polygon,
        db_session_factory,
        gemini_client=gemini,
        movers_per_direction=2,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        summary = await service.get_summary()
    finally:
        await polygon.aclose()
        await gemini.aclose()

    assert len(summary.top_gainers) == 2


async def test_summary_reorders_movers_by_change_not_provider_order(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """El recorte a `movers_per_direction` tiene que quedarse con los MAYORES, no con los
    primeros que mande el proveedor: su orden no se pudo verificar en vivo (ver la nota en
    `polygon_client.py`), y confiar en él daría un top-N equivocado.
    """

    await _seed_catalog(
        db_session_factory,
        [
            ("CHICO", "Alza chica", ExchangeType.NASDAQ),
            ("GRANDE", "Alza grande", ExchangeType.NASDAQ),
            ("MEDIO", "Alza media", ExchangeType.NASDAQ),
            ("SINDATO", "Sin variación", ExchangeType.NASDAQ),
            ("CAIDA", "Caída fuerte", ExchangeType.NYSE),
            ("ROCE", "Caída leve", ExchangeType.NYSE),
        ],
    )

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/gainers"):
            return httpx.Response(
                200,
                json={
                    "tickers": [
                        # Deliberadamente desordenado, y con una entrada sin variación.
                        {
                            "ticker": "CHICO",
                            "todaysChangePerc": 1.0,
                            "day": {"c": 10.0},
                        },
                        {"ticker": "SINDATO", "day": {"c": 10.0}},
                        {
                            "ticker": "GRANDE",
                            "todaysChangePerc": 9.0,
                            "day": {"c": 10.0},
                        },
                        {
                            "ticker": "MEDIO",
                            "todaysChangePerc": 5.0,
                            "day": {"c": 10.0},
                        },
                    ]
                },
            )
        return httpx.Response(
            200,
            json={
                "tickers": [
                    {"ticker": "ROCE", "todaysChangePerc": -0.5, "day": {"c": 10.0}},
                    {"ticker": "CAIDA", "todaysChangePerc": -8.0, "day": {"c": 10.0}},
                ]
            },
        )

    polygon = _polygon_client(httpx.MockTransport(handler))
    gemini = _gemini_client(_gemini_transport())
    service = MarketSummaryService(
        polygon,
        db_session_factory,
        gemini_client=gemini,
        movers_per_direction=3,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        summary = await service.get_summary()
    finally:
        await polygon.aclose()
        await gemini.aclose()

    # Alzas: de mayor a menor, y el que no trae variación queda fuera del top 3.
    assert [mover.ticker for mover in summary.top_gainers] == [
        "GRANDE",
        "MEDIO",
        "CHICO",
    ]
    # Bajas: la más negativa primero.
    assert [mover.ticker for mover in summary.top_losers] == ["CAIDA", "ROCE"]


async def test_summary_includes_only_context_tickers_in_prompt(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """El prompt exige que el modelo no mencione tickers fuera de `<market_data>`. Acá se verifica
    el otro lado del contrato: que el bloque contenga los movers filtrados y NO los descartados.
    """

    await _seed_catalog(
        db_session_factory, [("NVDA", "NVIDIA Corporation", ExchangeType.NASDAQ)]
    )

    calls: list[httpx.Request] = []
    polygon = _polygon_client(
        _polygon_transport(
            gainers=[("NVDA", 7.2, 950.0), ("FUERA", 30.0, 4.0)], losers=[]
        )
    )
    gemini = _gemini_client(_gemini_transport(calls))
    service = MarketSummaryService(
        polygon,
        db_session_factory,
        gemini_client=gemini,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        await service.get_summary()
    finally:
        await polygon.aclose()
        await gemini.aclose()

    assert len(calls) == 1
    sent = calls[0].content.decode()
    assert "NVDA" in sent
    assert "FUERA" not in sent
    assert "<market_data>" in sent


# --- Caché --------------------------------------------------------------------------------


async def test_summary_is_cached_and_not_recomputed(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(
        db_session_factory, [("NVDA", "NVIDIA Corporation", ExchangeType.NASDAQ)]
    )

    calls: list[httpx.Request] = []
    polygon = _polygon_client(
        _polygon_transport(gainers=[("NVDA", 7.2, 950.0)], losers=[])
    )
    gemini = _gemini_client(_gemini_transport(calls))
    service = MarketSummaryService(
        polygon,
        db_session_factory,
        gemini_client=gemini,
        cache_ttl_seconds=600.0,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        first = await service.get_summary()
        second = await service.get_summary()
    finally:
        await polygon.aclose()
        await gemini.aclose()

    # Una sola llamada al modelo para dos pedidos: esto es lo que la caché existe para lograr.
    assert len(calls) == 1
    assert first.served_from_cache is False
    assert second.served_from_cache is True
    assert second.headline == first.headline


async def test_summary_force_refresh_bypasses_cache(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(
        db_session_factory, [("NVDA", "NVIDIA Corporation", ExchangeType.NASDAQ)]
    )

    calls: list[httpx.Request] = []
    polygon = _polygon_client(
        _polygon_transport(gainers=[("NVDA", 7.2, 950.0)], losers=[])
    )
    gemini = _gemini_client(_gemini_transport(calls))
    service = MarketSummaryService(
        polygon,
        db_session_factory,
        gemini_client=gemini,
        cache_ttl_seconds=600.0,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        await service.get_summary()
        refreshed = await service.get_summary(force_refresh=True)
    finally:
        await polygon.aclose()
        await gemini.aclose()

    assert len(calls) == 2
    assert refreshed.served_from_cache is False


async def test_summary_expires_cache_after_ttl(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(
        db_session_factory, [("NVDA", "NVIDIA Corporation", ExchangeType.NASDAQ)]
    )

    calls: list[httpx.Request] = []
    polygon = _polygon_client(
        _polygon_transport(gainers=[("NVDA", 7.2, 950.0)], losers=[])
    )
    gemini = _gemini_client(_gemini_transport(calls))
    # TTL en cero: cualquier tiempo transcurrido la vence, sin tener que dormir el test.
    service = MarketSummaryService(
        polygon,
        db_session_factory,
        gemini_client=gemini,
        cache_ttl_seconds=0.0,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        await service.get_summary()
        await service.get_summary()
    finally:
        await polygon.aclose()
        await gemini.aclose()

    assert len(calls) == 2


async def test_summary_concurrent_requests_share_one_model_call(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """Sin el lock de refresco, N usuarios abriendo el Dashboard a la vez con la caché vacía
    disparan N llamadas a Gemini en paralelo — justo lo que la caché existe para evitar.
    """

    await _seed_catalog(
        db_session_factory, [("NVDA", "NVIDIA Corporation", ExchangeType.NASDAQ)]
    )

    calls: list[httpx.Request] = []
    polygon = _polygon_client(
        _polygon_transport(gainers=[("NVDA", 7.2, 950.0)], losers=[])
    )
    gemini = _gemini_client(_gemini_transport(calls))
    service = MarketSummaryService(
        polygon,
        db_session_factory,
        gemini_client=gemini,
        cache_ttl_seconds=600.0,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        results = await asyncio.gather(*(service.get_summary() for _ in range(5)))
    finally:
        await polygon.aclose()
        await gemini.aclose()

    assert len(calls) == 1
    assert all(result.headline == "Jornada mixta en Nasdaq." for result in results)


# --- Degradaciones ------------------------------------------------------------------------


async def test_summary_without_gemini_serves_movers_without_narrative(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(
        db_session_factory, [("NVDA", "NVIDIA Corporation", ExchangeType.NASDAQ)]
    )

    polygon = _polygon_client(
        _polygon_transport(gainers=[("NVDA", 7.2, 950.0)], losers=[])
    )
    service = MarketSummaryService(
        polygon, db_session_factory, gemini_client=None, system_prompt=_SYSTEM_PROMPT
    )

    try:
        summary = await service.get_summary()
    finally:
        await polygon.aclose()

    # Los datos duros siguen: el Dashboard muestra el heatmap de alzas aunque no haya IA.
    assert [mover.ticker for mover in summary.top_gainers] == ["NVDA"]
    assert summary.market_data_available is True
    assert summary.ai_narrative_available is False
    assert summary.headline is None
    assert summary.sentiment is None
    assert summary.degradation_reason is not None
    assert "GEMINI_API_KEY" in summary.degradation_reason


async def test_summary_without_market_data_does_not_call_the_model(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    calls: list[httpx.Request] = []
    # Catálogo vacío: ningún mover se puede atribuir a una bolsa ofrecida.
    polygon = _polygon_client(
        _polygon_transport(gainers=[("NVDA", 7.2, 950.0)], losers=[])
    )
    gemini = _gemini_client(_gemini_transport(calls))
    service = MarketSummaryService(
        polygon,
        db_session_factory,
        gemini_client=gemini,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        summary = await service.get_summary()
    finally:
        await polygon.aclose()
        await gemini.aclose()

    # Pedirle un resumen sin datos es pedirle que invente: no se lo invoca.
    assert calls == []
    assert summary.market_data_available is False
    assert summary.ai_narrative_available is False
    assert summary.top_gainers == []
    assert summary.degradation_reason is not None


async def test_summary_degrades_when_gemini_call_fails(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(
        db_session_factory, [("NVDA", "NVIDIA Corporation", ExchangeType.NASDAQ)]
    )

    def failing(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, json={"error": "boom"})

    polygon = _polygon_client(
        _polygon_transport(gainers=[("NVDA", 7.2, 950.0)], losers=[])
    )
    gemini = _gemini_client(httpx.MockTransport(failing))
    service = MarketSummaryService(
        polygon,
        db_session_factory,
        gemini_client=gemini,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        summary = await service.get_summary()
    finally:
        await polygon.aclose()
        await gemini.aclose()

    assert summary.market_data_available is True
    assert summary.ai_narrative_available is False
    assert summary.headline is None
    assert [mover.ticker for mover in summary.top_gainers] == ["NVDA"]
    assert summary.degradation_reason is not None


async def test_summary_rejects_unexpected_sentiment_label(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """El `response_schema` declara el enum, pero no se confía en que el proveedor lo respete:
    un label libre llegaría hasta la UI y rompería el pintado por sentimiento.
    """

    await _seed_catalog(
        db_session_factory, [("NVDA", "NVIDIA Corporation", ExchangeType.NASDAQ)]
    )

    polygon = _polygon_client(
        _polygon_transport(gainers=[("NVDA", 7.2, 950.0)], losers=[])
    )
    gemini = _gemini_client(_gemini_transport(sentiment="EUFÓRICO"))
    service = MarketSummaryService(
        polygon,
        db_session_factory,
        gemini_client=gemini,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        summary = await service.get_summary()
    finally:
        await polygon.aclose()
        await gemini.aclose()

    assert summary.ai_narrative_available is False
    assert summary.sentiment is None
    assert summary.degradation_reason is not None


async def test_summary_degrades_when_output_is_not_json(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(
        db_session_factory, [("NVDA", "NVIDIA Corporation", ExchangeType.NASDAQ)]
    )

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "finishReason": "STOP",
                        "content": {"parts": [{"text": "esto no es JSON"}]},
                    }
                ]
            },
        )

    polygon = _polygon_client(
        _polygon_transport(gainers=[("NVDA", 7.2, 950.0)], losers=[])
    )
    gemini = _gemini_client(httpx.MockTransport(handler))
    service = MarketSummaryService(
        polygon,
        db_session_factory,
        gemini_client=gemini,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        summary = await service.get_summary()
    finally:
        await polygon.aclose()
        await gemini.aclose()

    assert summary.ai_narrative_available is False
    assert summary.degradation_reason is not None


# --- Endpoint -----------------------------------------------------------------------------


async def test_market_summary_endpoint_returns_503_when_not_configured(
    client: httpx.AsyncClient,
) -> None:
    await client.post(
        "/api/v1/auth/register",
        json={"email": "summary-user@example.com", "password": "supersecreta1"},
    )
    login = await client.post(
        "/api/v1/auth/login",
        json={"email": "summary-user@example.com", "password": "supersecreta1"},
    )
    headers = {"Authorization": f"Bearer {login.json()['access_token']}"}

    response = await client.get("/api/v1/market/summary", headers=headers)
    assert response.status_code == 503
    assert "POLYGON_API_KEY" in response.json()["detail"]


async def test_market_summary_endpoint_requires_auth(
    client: httpx.AsyncClient,
) -> None:
    response = await client.get("/api/v1/market/summary")
    assert response.status_code == 401


async def test_market_summary_endpoint_serves_configured_service(
    client: httpx.AsyncClient,
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    from app.main import app

    await _seed_catalog(
        db_session_factory, [("NVDA", "NVIDIA Corporation", ExchangeType.NASDAQ)]
    )

    polygon = _polygon_client(
        _polygon_transport(gainers=[("NVDA", 7.2, 950.0)], losers=[])
    )
    gemini = _gemini_client(_gemini_transport())
    app.state.market_summary_service = MarketSummaryService(
        polygon,
        db_session_factory,
        gemini_client=gemini,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        await client.post(
            "/api/v1/auth/register",
            json={"email": "summary-ok@example.com", "password": "supersecreta1"},
        )
        login = await client.post(
            "/api/v1/auth/login",
            json={"email": "summary-ok@example.com", "password": "supersecreta1"},
        )
        headers = {"Authorization": f"Bearer {login.json()['access_token']}"}

        response = await client.get("/api/v1/market/summary", headers=headers)
    finally:
        app.state.market_summary_service = None
        await polygon.aclose()
        await gemini.aclose()

    assert response.status_code == 200
    body = response.json()
    assert body["ai_narrative_available"] is True
    assert body["headline"] == "Jornada mixta en Nasdaq."
    assert [mover["ticker"] for mover in body["top_gainers"]] == ["NVDA"]
    assert body["exchanges"] == ["NASDAQ", "NYSE"]
