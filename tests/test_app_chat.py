"""Tests de `ChatService` y `POST /api/v1/chat`: arma contexto desde `AlertHistory`, fuerza
salida JSON vía Gemini (sin red real, `httpx.MockTransport`), y degrada explícito ante un
fallo de proveedor o una respuesta inválida — nunca inventa una respuesta.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone

import httpx
import pytest
from pydantic import ValidationError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.alert_history import AlertHistory
from app.models.enums import AssetType, ExchangeType
from app.models.ticker import Ticker
from app.schemas.chat import ChatRequest
from app.schemas.market import MarketMoverOut, MarketSummary, TickerQuote
from app.services.chat_service import ChatService
from src.ingestion.gemini_client import GeminiClient
from src.validation.domain_models import AlertSeverity, DataStatus

_SYSTEM_PROMPT = 'Sos un asistente de prueba. Respondé {"reply": "..."}'


def _gemini_client(handler: httpx.MockTransport) -> GeminiClient:
    return GeminiClient(
        "fake-key",
        http_client=httpx.AsyncClient(
            transport=handler,
            base_url="https://generativelanguage.googleapis.com/v1beta",
        ),
    )


def _ok_handler(reply: str) -> httpx.MockTransport:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "finishReason": "STOP",
                        "content": {"parts": [{"text": json.dumps({"reply": reply})}]},
                    }
                ]
            },
        )

    return httpx.MockTransport(handler)


async def test_chat_answers_without_ticker(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    gemini = _gemini_client(_ok_handler("Hola, ¿en qué te ayudo?"))
    service = ChatService(gemini, db_session_factory, system_prompt=_SYSTEM_PROMPT)

    try:
        result = await service.answer("hola", None)
        assert result.reply == "Hola, ¿en qué te ayudo?"
        assert result.referenced_ticker is None
        assert result.grounded_in_recent_alert is False
    finally:
        await gemini.aclose()


async def test_chat_grounds_in_recent_alert_history(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    async with db_session_factory() as session:
        session.add(
            AlertHistory(
                ticker="NVDA",
                payload_json={
                    "ticker": "NVDA",
                    "short_summary": "Sube 5% por earnings",
                },
                urgency_level=AlertSeverity.MEDIUM,
            )
        )
        await session.commit()

    gemini = _gemini_client(_ok_handler("NVDA subió por earnings."))
    service = ChatService(gemini, db_session_factory, system_prompt=_SYSTEM_PROMPT)

    try:
        result = await service.answer("¿qué pasó con NVDA?", "nvda")
        assert result.reply == "NVDA subió por earnings."
        assert result.referenced_ticker == "NVDA"
        assert result.grounded_in_recent_alert is True
    finally:
        await gemini.aclose()


async def test_chat_reports_no_recent_context_without_grounding(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    gemini = _gemini_client(_ok_handler("No tengo datos recientes de GOOG."))
    service = ChatService(gemini, db_session_factory, system_prompt=_SYSTEM_PROMPT)

    try:
        result = await service.answer("¿y GOOG?", "GOOG")
        assert result.grounded_in_recent_alert is False
        assert result.referenced_ticker == "GOOG"
    finally:
        await gemini.aclose()


async def test_chat_degrades_when_gemini_call_fails(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, json={"error": "boom"})

    gemini = _gemini_client(httpx.MockTransport(handler))
    service = ChatService(gemini, db_session_factory, system_prompt=_SYSTEM_PROMPT)

    try:
        result = await service.answer("hola", None)
        assert "no pude generar" in result.reply.lower()
    finally:
        await gemini.aclose()


async def test_chat_degrades_when_output_is_invalid_json(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
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

    gemini = _gemini_client(httpx.MockTransport(handler))
    service = ChatService(gemini, db_session_factory, system_prompt=_SYSTEM_PROMPT)

    try:
        result = await service.answer("hola", None)
        assert "no pude interpretar" in result.reply.lower()
    finally:
        await gemini.aclose()


async def test_chat_endpoint_returns_503_when_not_configured(
    client: httpx.AsyncClient,
) -> None:
    await client.post(
        "/api/v1/auth/register",
        json={"email": "chat-user@example.com", "password": "supersecreta1"},
    )
    login = await client.post(
        "/api/v1/auth/login",
        json={"email": "chat-user@example.com", "password": "supersecreta1"},
    )
    headers = {"Authorization": f"Bearer {login.json()['access_token']}"}

    response = await client.post(
        "/api/v1/chat", json={"prompt": "hola"}, headers=headers
    )
    assert response.status_code == 503


async def test_chat_endpoint_requires_auth(client: httpx.AsyncClient) -> None:
    response = await client.post("/api/v1/chat", json={"prompt": "hola"})
    assert response.status_code == 401


# --- Contexto dinámico por ticker ---------------------------------------------------------


class _StubQuoteProvider:
    """Doble de `MarketDataService`. Implementa `QuoteProviderLike` por estructura (Protocol),
    sin heredar de un servicio que envuelve un cliente HTTP.
    """

    def __init__(self, quotes: list[TickerQuote], *, fail: bool = False) -> None:
        self._quotes = quotes
        self._fail = fail
        self.requested: list[tuple[str, AssetType]] = []

    async def get_quotes(self, items: list[tuple[str, AssetType]]) -> list[TickerQuote]:
        self.requested.extend(items)
        if self._fail:
            raise RuntimeError("proveedor caído")
        return self._quotes


class _StubMarketSummary:
    def __init__(self, summary: MarketSummary, *, fail: bool = False) -> None:
        self._summary = summary
        self._fail = fail
        self.calls = 0

    async def get_summary(self, *, force_refresh: bool = False) -> MarketSummary:
        self.calls += 1
        if self._fail:
            raise RuntimeError("resumen caído")
        return self._summary


def _capturing_handler(calls: list[httpx.Request], reply: str) -> httpx.MockTransport:
    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "finishReason": "STOP",
                        "content": {"parts": [{"text": json.dumps({"reply": reply})}]},
                    }
                ]
            },
        )

    return httpx.MockTransport(handler)


def _summary_with(gainers: list[tuple[str, float]]) -> MarketSummary:
    return MarketSummary(
        generated_at=datetime(2026, 8, 4, 17, 0, tzinfo=timezone.utc),
        exchanges=[ExchangeType.NASDAQ, ExchangeType.NYSE],
        top_gainers=[
            MarketMoverOut(
                ticker=ticker,
                name=None,
                exchange=ExchangeType.NASDAQ,
                last_price=100.0,
                day_change_pct=change,
            )
            for ticker, change in gainers
        ],
        top_losers=[],
        market_data_available=bool(gainers),
    )


async def _seed_ticker(
    session_factory: async_sessionmaker[AsyncSession],
    symbol: str,
    name: str,
    exchange: ExchangeType,
) -> None:
    async with session_factory() as session:
        session.add(
            Ticker(
                symbol=symbol,
                name=name,
                primary_exchange="XNAS" if exchange == ExchangeType.NASDAQ else "XNYS",
                exchange=exchange,
                asset_type="CS",
                active=True,
            )
        )
        await session.commit()


async def test_chat_injects_live_quote_and_exchange_for_the_ticker(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_ticker(
        db_session_factory, "NVDA", "NVIDIA Corporation", ExchangeType.NASDAQ
    )

    calls: list[httpx.Request] = []
    gemini = _gemini_client(_capturing_handler(calls, "NVDA opera en alza."))
    quotes = _StubQuoteProvider(
        [
            TickerQuote(
                ticker="NVDA",
                last_price=950.25,
                day_change_pct=7.2,
                status=DataStatus.OK,
            )
        ]
    )
    service = ChatService(
        gemini,
        db_session_factory,
        system_prompt=_SYSTEM_PROMPT,
        quote_provider=quotes,
    )

    try:
        result = await service.answer("¿cómo viene NVDA?", "nvda")
    finally:
        await gemini.aclose()

    assert result.referenced_ticker == "NVDA"
    # El ticker se normaliza a mayúsculas antes de pedir la cotización.
    assert quotes.requested == [("NVDA", AssetType.STOCK)]

    sent = calls[0].content.decode()
    assert "950.25" in sent
    assert "+7.20%" in sent
    assert "NASDAQ" in sent
    assert "NVIDIA Corporation" in sent


async def test_chat_uses_crypto_asset_type_for_dashed_symbols(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """`BTC-USD` no está en el catálogo de acciones: el `asset_type` se deduce de la forma del
    símbolo, porque el body del chat no lo pide.
    """

    gemini = _gemini_client(_ok_handler("BTC se mueve fuerte."))
    quotes = _StubQuoteProvider(
        [
            TickerQuote(
                ticker="BTC-USD",
                last_price=61000.0,
                day_change_pct=-2.5,
                status=DataStatus.OK,
            )
        ]
    )
    service = ChatService(
        gemini,
        db_session_factory,
        system_prompt=_SYSTEM_PROMPT,
        quote_provider=quotes,
    )

    try:
        await service.answer("¿y BTC?", "btc-usd")
    finally:
        await gemini.aclose()

    assert quotes.requested == [("BTC-USD", AssetType.CRYPTO)]


async def test_chat_declares_missing_ticker_in_catalog(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    calls: list[httpx.Request] = []
    gemini = _gemini_client(_capturing_handler(calls, "No conozco esa bolsa."))
    service = ChatService(gemini, db_session_factory, system_prompt=_SYSTEM_PROMPT)

    try:
        await service.answer("¿y ZZZZ?", "ZZZZ")
    finally:
        await gemini.aclose()

    sent = calls[0].content.decode()
    # El prompt tiene que decir explícitamente que no se puede afirmar la bolsa, para que el
    # modelo no la invente.
    assert "no está en el catálogo local" in sent


async def test_chat_declares_unconfigured_quotes_instead_of_omitting_the_block(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    calls: list[httpx.Request] = []
    gemini = _gemini_client(_capturing_handler(calls, "No tengo el precio."))
    # Sin quote_provider: Polygon no configurado en este entorno.
    service = ChatService(gemini, db_session_factory, system_prompt=_SYSTEM_PROMPT)

    try:
        result = await service.answer("¿precio de NVDA?", "NVDA")
    finally:
        await gemini.aclose()

    assert result.referenced_ticker == "NVDA"
    sent = calls[0].content.decode()
    assert "<live_quote>" in sent
    assert "no están configurados" in sent


async def test_chat_degrades_quote_block_when_provider_raises(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    calls: list[httpx.Request] = []
    gemini = _gemini_client(_capturing_handler(calls, "Sin cotización."))
    service = ChatService(
        gemini,
        db_session_factory,
        system_prompt=_SYSTEM_PROMPT,
        quote_provider=_StubQuoteProvider([], fail=True),
    )

    try:
        # Un proveedor caído degrada ese bloque, no tumba el chat entero.
        result = await service.answer("¿precio de NVDA?", "NVDA")
    finally:
        await gemini.aclose()

    assert result.reply == "Sin cotización."
    assert "No se pudo obtener la cotización en vivo" in calls[0].content.decode()


async def test_chat_marks_quote_unavailable_when_status_is_not_ok(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    calls: list[httpx.Request] = []
    gemini = _gemini_client(_capturing_handler(calls, "Sin dato."))
    service = ChatService(
        gemini,
        db_session_factory,
        system_prompt=_SYSTEM_PROMPT,
        quote_provider=_StubQuoteProvider(
            [
                TickerQuote(
                    ticker="NVDA",
                    last_price=None,
                    day_change_pct=None,
                    status=DataStatus.ERROR_API,
                )
            ]
        ),
    )

    try:
        await service.answer("¿precio?", "NVDA")
    finally:
        await gemini.aclose()

    assert "Sin cotización disponible para NVDA" in calls[0].content.decode()


async def test_chat_combines_live_quote_with_recent_analysis(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """Los bloques son independientes: tener cotización Y análisis reciente es el caso completo,
    y `grounded_in_recent_alert` se sigue fijando por el análisis, no por la cotización.
    """

    await _seed_ticker(db_session_factory, "AAPL", "Apple Inc.", ExchangeType.NASDAQ)
    async with db_session_factory() as session:
        session.add(
            AlertHistory(
                ticker="AAPL",
                payload_json={"ticker": "AAPL", "short_summary": "Baja por un recorte"},
                urgency_level=AlertSeverity.MEDIUM,
            )
        )
        await session.commit()

    calls: list[httpx.Request] = []
    gemini = _gemini_client(_capturing_handler(calls, "AAPL bajó."))
    service = ChatService(
        gemini,
        db_session_factory,
        system_prompt=_SYSTEM_PROMPT,
        quote_provider=_StubQuoteProvider(
            [
                TickerQuote(
                    ticker="AAPL",
                    last_price=210.0,
                    day_change_pct=-3.4,
                    status=DataStatus.OK,
                )
            ]
        ),
    )

    try:
        result = await service.answer("¿qué pasó con AAPL?", "AAPL")
    finally:
        await gemini.aclose()

    assert result.grounded_in_recent_alert is True
    sent = calls[0].content.decode()
    assert "210.0" in sent
    assert "-3.40%" in sent
    assert "Baja por un recorte" in sent


# --- Contexto general de mercado (sin ticker) ----------------------------------------------


async def test_chat_without_ticker_injects_general_market_context(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    calls: list[httpx.Request] = []
    gemini = _gemini_client(_capturing_handler(calls, "El mercado viene mixto."))
    summary = _StubMarketSummary(_summary_with([("NVDA", 7.2), ("AMD", 4.1)]))
    service = ChatService(
        gemini,
        db_session_factory,
        system_prompt=_SYSTEM_PROMPT,
        market_summary=summary,
    )

    try:
        result = await service.answer("¿cómo viene el mercado?", None)
    finally:
        await gemini.aclose()

    assert result.referenced_ticker is None
    assert result.grounded_in_recent_alert is False
    # Se lee de la caché del resumen: una pregunta general no dispara una llamada nueva a
    # Polygon por cada mensaje del chat.
    assert summary.calls == 1

    sent = calls[0].content.decode()
    assert "<market_context>" in sent
    assert "NVDA" in sent
    assert "+7.20%" in sent


async def test_chat_without_ticker_declares_absent_market_data(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    calls: list[httpx.Request] = []
    gemini = _gemini_client(_capturing_handler(calls, "No tengo datos de hoy."))
    service = ChatService(
        gemini,
        db_session_factory,
        system_prompt=_SYSTEM_PROMPT,
        market_summary=_StubMarketSummary(_summary_with([])),
    )

    try:
        await service.answer("¿cómo viene el mercado?", None)
    finally:
        await gemini.aclose()

    assert "No hay datos de alzas y bajas" in calls[0].content.decode()


async def test_chat_without_ticker_degrades_when_summary_raises(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    calls: list[httpx.Request] = []
    gemini = _gemini_client(_capturing_handler(calls, "Respuesta general."))
    service = ChatService(
        gemini,
        db_session_factory,
        system_prompt=_SYSTEM_PROMPT,
        market_summary=_StubMarketSummary(_summary_with([("NVDA", 1.0)]), fail=True),
    )

    try:
        result = await service.answer("¿y el mercado?", None)
    finally:
        await gemini.aclose()

    assert result.reply == "Respuesta general."
    assert "No se pudo obtener el estado del mercado" in calls[0].content.decode()


def test_chat_request_rejects_an_empty_ticker() -> None:
    """El `ticker` viaja en el body y se valida en el schema: vacío es un error, no "pregunta sin
    contexto". Se prueba sobre `ChatRequest` y no vía HTTP porque FastAPI resuelve las
    dependencias antes de validar el body — con el chat sin configurar, el 503 de la dependencia
    se adelantaría al 422 y el test no probaría nada del schema.
    """

    with pytest.raises(ValidationError):
        ChatRequest(prompt="hola", ticker="")

    assert ChatRequest(prompt="hola", ticker="NVDA").ticker == "NVDA"
    assert ChatRequest(prompt="hola").ticker is None


async def test_chat_endpoint_passes_body_ticker_through_to_the_service(
    client: httpx.AsyncClient,
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """Camino completo del endpoint con el servicio configurado: el `ticker` del body llega al
    `ChatService`, se normaliza y vuelve en `referenced_ticker`.
    """

    from app.main import app

    await _seed_ticker(
        db_session_factory, "NVDA", "NVIDIA Corporation", ExchangeType.NASDAQ
    )

    calls: list[httpx.Request] = []
    gemini = _gemini_client(_capturing_handler(calls, "NVDA opera en alza."))
    app.state.chat_service = ChatService(
        gemini,
        db_session_factory,
        system_prompt=_SYSTEM_PROMPT,
        quote_provider=_StubQuoteProvider(
            [
                TickerQuote(
                    ticker="NVDA",
                    last_price=950.25,
                    day_change_pct=7.2,
                    status=DataStatus.OK,
                )
            ]
        ),
    )

    try:
        await client.post(
            "/api/v1/auth/register",
            json={"email": "chat-ok@example.com", "password": "supersecreta1"},
        )
        login = await client.post(
            "/api/v1/auth/login",
            json={"email": "chat-ok@example.com", "password": "supersecreta1"},
        )
        headers = {"Authorization": f"Bearer {login.json()['access_token']}"}

        response = await client.post(
            "/api/v1/chat",
            json={"prompt": "¿cómo viene?", "ticker": "nvda"},
            headers=headers,
        )
    finally:
        app.state.chat_service = None
        await gemini.aclose()

    assert response.status_code == 200
    body = response.json()
    assert body["reply"] == "NVDA opera en alza."
    assert body["referenced_ticker"] == "NVDA"
    # El contexto que salió hacia el modelo lleva la cotización en vivo del ticker pedido.
    assert "950.25" in calls[0].content.decode()
