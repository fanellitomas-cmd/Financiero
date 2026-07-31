"""Tests de `ChatService` y `POST /api/v1/chat`: arma contexto desde `AlertHistory`, fuerza
salida JSON vía Gemini (sin red real, `httpx.MockTransport`), y degrada explícito ante un
fallo de proveedor o una respuesta inválida — nunca inventa una respuesta.
"""

from __future__ import annotations

import json

import httpx
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.alert_history import AlertHistory
from app.services.chat_service import ChatService
from src.ingestion.gemini_client import GeminiClient
from src.validation.domain_models import AlertSeverity

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
