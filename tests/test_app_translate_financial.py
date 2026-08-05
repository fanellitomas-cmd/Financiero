"""Tests de `FinancialTranslatorService` y `POST /api/v1/ai/translate-financial`.

Los contratos que este bloque promete y que son fáciles de romper sin darse cuenta:

  1. **Sin credenciales de IA la respuesta sigue teniendo forma válida** (`available=False` con su
     motivo), no un 503: el "Explicar para Principiantes" es una ayuda opcional, y un error de
     transporte lo haría parecer una falla de la pantalla que lo contiene.
  2. **La caché es por contenido.** El mismo texto pedido dos veces (por el mismo usuario o por
     otro) gasta una sola llamada al modelo; cambiar el contexto es otra entrada, porque cambia la
     respuesta.
  3. **Una respuesta vacía o ilegible del modelo se trata como no disponible**, nunca como una
     traducción con los campos en blanco.
  4. **La analogía es opcional.** Es mejor no dar ninguna que dar una forzada.
"""

from __future__ import annotations

import json

import httpx

from app.services.financial_translator_service import FinancialTranslatorService
from src.ingestion.gemini_client import GeminiClient

_SYSTEM_PROMPT = "Sos un traductor financiero de prueba. Devolvé el JSON pedido."
_TEXT = "El múltiplo se comprimió por deterioro del margen operativo."


def _gemini_client(transport: httpx.MockTransport) -> GeminiClient:
    return GeminiClient(
        "fake-key",
        http_client=httpx.AsyncClient(
            transport=transport,
            base_url="https://generativelanguage.googleapis.com/v1beta",
        ),
    )


def _gemini_transport(
    payload: dict[str, object] | None = None,
    *,
    raw_text: str | None = None,
    status_code: int = 200,
    prompts: list[str] | None = None,
) -> httpx.MockTransport:
    def handler(request: httpx.Request) -> httpx.Response:
        if prompts is not None:
            prompts.append(request.read().decode("utf-8"))
        if status_code != 200:
            return httpx.Response(status_code, json={"error": "boom"})
        text = raw_text if raw_text is not None else json.dumps(payload or {})
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "finishReason": "STOP",
                        "content": {"parts": [{"text": text}]},
                    }
                ]
            },
        )

    return httpx.MockTransport(handler)


_FULL_PAYLOAD: dict[str, object] = {
    "simple_explanation": (
        "La empresa gana menos por cada peso que vende, y por eso el mercado está dispuesto a "
        "pagar menos por sus ganancias."
    ),
    "analogy": (
        "Es como un kiosco que sigue vendiendo lo mismo pero le queda menos plata al final del "
        "día porque le subió el alquiler."
    ),
    "key_terms": [
        {
            "term": "múltiplo",
            "plain_meaning": "cuánto paga el mercado por cada peso de ganancia.",
        },
        {
            "term": "margen operativo",
            "plain_meaning": "qué parte de lo que vende le queda después de los costos de operar.",
        },
    ],
}


# --- Servicio --------------------------------------------------------------------------------


async def test_translation_separates_explanation_analogy_and_glossary() -> None:
    service = FinancialTranslatorService(
        gemini_client=_gemini_client(_gemini_transport(_FULL_PAYLOAD)),
        system_prompt=_SYSTEM_PROMPT,
    )

    translation = await service.translate(_TEXT, context="NVDA · Ficha de inteligencia")

    assert translation.available is True
    assert translation.original_text == _TEXT
    assert translation.simple_explanation is not None
    assert "gana menos por cada peso" in translation.simple_explanation
    # La analogía viaja aparte de la explicación: es una ayuda para entender, no una afirmación
    # sobre la empresa, y mezclarlas dejaría al lector sin saber cuál de las dos es el dato.
    assert translation.analogy is not None
    assert "kiosco" in translation.analogy
    assert [entry.term for entry in translation.key_terms] == [
        "múltiplo",
        "margen operativo",
    ]


async def test_the_prompt_carries_the_text_and_the_context() -> None:
    prompts: list[str] = []
    service = FinancialTranslatorService(
        gemini_client=_gemini_client(_gemini_transport(_FULL_PAYLOAD, prompts=prompts)),
        system_prompt=_SYSTEM_PROMPT,
    )

    await service.translate(_TEXT, context="JPM · alerta de deterioro")

    assert "<texto_original>" in prompts[0]
    assert "JPM" in prompts[0]


async def test_missing_context_is_declared_not_omitted() -> None:
    """Si el bloque de contexto no apareciera, el modelo no tendría cómo saber que no hay contexto
    y podría suponer uno.
    """

    prompts: list[str] = []
    service = FinancialTranslatorService(
        gemini_client=_gemini_client(_gemini_transport(_FULL_PAYLOAD, prompts=prompts)),
        system_prompt=_SYSTEM_PROMPT,
    )

    await service.translate(_TEXT)

    assert "sin contexto adicional" in prompts[0]


async def test_analogy_is_optional() -> None:
    """Una analogía forzada confunde más que el término original, y una equivocada enseña algo
    falso: el modelo puede no dar ninguna y eso es una respuesta válida.
    """

    service = FinancialTranslatorService(
        gemini_client=_gemini_client(
            _gemini_transport({"simple_explanation": "Explicación sin analogía."})
        ),
        system_prompt=_SYSTEM_PROMPT,
    )

    translation = await service.translate("EBITDA")

    assert translation.available is True
    assert translation.analogy is None
    assert translation.key_terms == []


async def test_blank_glossary_entries_are_dropped() -> None:
    service = FinancialTranslatorService(
        gemini_client=_gemini_client(
            _gemini_transport(
                {
                    "simple_explanation": "Explicación.",
                    "key_terms": [
                        {"term": "  ", "plain_meaning": "algo"},
                        {"term": "P/E", "plain_meaning": "   "},
                        {
                            "term": "ROE",
                            "plain_meaning": "cuánto rinde el capital propio.",
                        },
                    ],
                }
            )
        ),
        system_prompt=_SYSTEM_PROMPT,
    )

    translation = await service.translate("P/E, ROE")

    assert [entry.term for entry in translation.key_terms] == ["ROE"]


async def test_without_gemini_returns_a_valid_unavailable_response() -> None:
    service = FinancialTranslatorService(system_prompt=_SYSTEM_PROMPT)

    translation = await service.translate(_TEXT)

    assert translation.available is False
    assert translation.simple_explanation is None
    assert translation.original_text == _TEXT
    assert translation.degradation_reason is not None
    assert "GEMINI_API_KEY" in translation.degradation_reason


async def test_provider_failure_is_reported_not_raised() -> None:
    service = FinancialTranslatorService(
        gemini_client=_gemini_client(_gemini_transport(status_code=500)),
        system_prompt=_SYSTEM_PROMPT,
    )

    translation = await service.translate(_TEXT)

    assert translation.available is False
    assert translation.degradation_reason is not None
    assert "falló la consulta al modelo" in translation.degradation_reason


async def test_unparseable_output_is_reported_as_unavailable() -> None:
    service = FinancialTranslatorService(
        gemini_client=_gemini_client(_gemini_transport(raw_text="no soy json")),
        system_prompt=_SYSTEM_PROMPT,
    )

    translation = await service.translate(_TEXT)

    assert translation.available is False
    assert translation.simple_explanation is None


async def test_an_empty_explanation_is_not_served_as_available() -> None:
    """Una explicación vacía es una respuesta fallida con forma válida: devolverla con
    `available=True` dejaría al cliente mostrando una tarjeta en blanco.
    """

    service = FinancialTranslatorService(
        gemini_client=_gemini_client(_gemini_transport({"simple_explanation": "   "})),
        system_prompt=_SYSTEM_PROMPT,
    )

    translation = await service.translate(_TEXT)

    assert translation.available is False
    assert translation.degradation_reason is not None


# --- Caché -----------------------------------------------------------------------------------


async def test_the_same_text_is_translated_once() -> None:
    prompts: list[str] = []
    service = FinancialTranslatorService(
        gemini_client=_gemini_client(_gemini_transport(_FULL_PAYLOAD, prompts=prompts)),
        system_prompt=_SYSTEM_PROMPT,
    )

    first = await service.translate(_TEXT, context="NVDA")
    second = await service.translate(_TEXT, context="NVDA")

    assert len(prompts) == 1
    assert first.served_from_cache is False
    assert second.served_from_cache is True
    assert second.simple_explanation == first.simple_explanation


async def test_a_different_context_is_a_different_translation() -> None:
    """El mismo término explicado sobre una tecnológica y sobre un banco no da lo mismo, así que el
    contexto entra en la clave de caché.
    """

    prompts: list[str] = []
    service = FinancialTranslatorService(
        gemini_client=_gemini_client(_gemini_transport(_FULL_PAYLOAD, prompts=prompts)),
        system_prompt=_SYSTEM_PROMPT,
    )

    await service.translate(_TEXT, context="NVDA")
    await service.translate(_TEXT, context="JPM")

    assert len(prompts) == 2


async def test_failures_are_not_cached() -> None:
    """Cachear un fallo dejaría el término roto por 24 horas para todo el mundo.

    El status es 400 y no 500 a propósito: 500 está en los reintentables de `http_utils`, así que
    cada `translate` haría tres requests y el conteo dejaría de medir lo que este test quiere medir.
    """

    prompts: list[str] = []
    service = FinancialTranslatorService(
        gemini_client=_gemini_client(
            _gemini_transport(status_code=400, prompts=prompts)
        ),
        system_prompt=_SYSTEM_PROMPT,
    )

    first = await service.translate(_TEXT)
    second = await service.translate(_TEXT)

    assert first.available is False
    assert second.available is False
    assert second.served_from_cache is False
    assert len(prompts) == 2


async def test_the_cache_is_bounded() -> None:
    """Sin tope, un cliente que traduzca textos siempre distintos haría crecer el diccionario sin
    límite mientras el proceso viva.
    """

    prompts: list[str] = []
    service = FinancialTranslatorService(
        gemini_client=_gemini_client(_gemini_transport(_FULL_PAYLOAD, prompts=prompts)),
        max_cache_entries=2,
        system_prompt=_SYSTEM_PROMPT,
    )

    await service.translate("primero")
    await service.translate("segundo")
    await service.translate("tercero")
    # El primero fue desalojado, así que volver a pedirlo cuesta otra llamada.
    await service.translate("primero")

    assert len(prompts) == 4
    # El último sigue cacheado.
    repeated = await service.translate("tercero")
    assert repeated.served_from_cache is True


async def test_an_expired_entry_is_recomputed() -> None:
    prompts: list[str] = []
    service = FinancialTranslatorService(
        gemini_client=_gemini_client(_gemini_transport(_FULL_PAYLOAD, prompts=prompts)),
        # TTL de 0: toda entrada está vencida en la siguiente lectura.
        cache_ttl_seconds=0.0,
        system_prompt=_SYSTEM_PROMPT,
    )

    await service.translate(_TEXT)
    second = await service.translate(_TEXT)

    assert len(prompts) == 2
    assert second.served_from_cache is False


# --- Endpoint --------------------------------------------------------------------------------


async def _auth_headers(client: httpx.AsyncClient, email: str) -> dict[str, str]:
    await client.post(
        "/api/v1/auth/register", json={"email": email, "password": "supersecreta1"}
    )
    login = await client.post(
        "/api/v1/auth/login", json={"email": email, "password": "supersecreta1"}
    )
    return {"Authorization": f"Bearer {login.json()['access_token']}"}


async def test_translate_endpoint_requires_authentication(
    client: httpx.AsyncClient,
) -> None:
    response = await client.post(
        "/api/v1/ai/translate-financial", json={"text": "EBITDA"}
    )

    assert response.status_code == 401


async def test_translate_endpoint_degrades_without_credentials(
    client: httpx.AsyncClient,
) -> None:
    """El servicio de la conftest no tiene Gemini: 200 con `available=false`, no 503."""

    headers = await _auth_headers(client, "translate@example.com")

    response = await client.post(
        "/api/v1/ai/translate-financial",
        json={"text": _TEXT, "context": "NVDA"},
        headers=headers,
    )

    assert response.status_code == 200
    body = response.json()
    assert body["available"] is False
    assert body["original_text"] == _TEXT
    assert body["simple_explanation"] is None
    assert "GEMINI_API_KEY" in body["degradation_reason"]


async def test_translate_endpoint_serves_a_configured_translator(
    client: httpx.AsyncClient,
) -> None:
    from app.main import app

    app.state.financial_translator_service = FinancialTranslatorService(
        gemini_client=_gemini_client(_gemini_transport(_FULL_PAYLOAD)),
        system_prompt=_SYSTEM_PROMPT,
    )
    headers = await _auth_headers(client, "translate-ok@example.com")

    response = await client.post(
        "/api/v1/ai/translate-financial",
        json={"text": _TEXT, "context": "NVDA"},
        headers=headers,
    )

    assert response.status_code == 200
    body = response.json()
    assert body["available"] is True
    assert "gana menos por cada peso" in body["simple_explanation"]
    assert body["analogy"] is not None
    assert len(body["key_terms"]) == 2


async def test_translate_endpoint_rejects_an_empty_text(
    client: httpx.AsyncClient,
) -> None:
    headers = await _auth_headers(client, "translate-empty@example.com")

    response = await client.post(
        "/api/v1/ai/translate-financial", json={"text": "x"}, headers=headers
    )

    assert response.status_code == 422
