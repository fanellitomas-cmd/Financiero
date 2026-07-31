"""Cliente de ingesta para la API de Gemini (Google Generative Language API): genera texto
forzado a JSON estructurado a partir de un system prompt + contenido de usuario.

NOTA DE VERIFICACIÓN — igual que con `fmp_client.py`: el entorno de desarrollo no tuvo acceso
de red a generativelanguage.googleapis.com para confirmar en vivo el contrato exacto (esta vez
la confianza es alta, es una API REST estable y muy documentada, pero no verificada en vivo).
Puntos a confirmar contra una llamada real antes de producción:
  - El campo top-level `system_instruction` (snake_case) vs. el resto del body en camelCase.
  - El dialecto exacto de `responseSchema` (tipos en minúscula vs. mayúscula, soporte de
    `enum`/`required` anidados) para la versión de API que uses.
Si el contrato real difiere, esto falla con `ProviderResponseError` (JSON inesperado) o con
un `finish_reason` no-STOP — nunca se inventa una respuesta.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from types import TracebackType
from typing import Any, Self

import httpx

from src.core.exceptions import (
    ProviderAuthenticationError,
    ProviderRateLimitError,
    ProviderResponseError,
    ProviderTimeoutError,
)
from src.core.http_utils import request_with_retries
from src.ingestion.schemas_raw import GeminiGenerationResult
from src.validation.domain_models import DataStatus

logger = logging.getLogger(__name__)

_PROVIDER_NAME = "gemini"


class GeminiClient:
    def __init__(
        self,
        api_key: str,
        *,
        base_url: str = "https://generativelanguage.googleapis.com/v1beta",
        model: str = "gemini-1.5-pro",
        timeout_seconds: float = 30.0,
        max_retry_attempts: int = 3,
        http_client: httpx.AsyncClient | None = None,
    ) -> None:
        self._api_key = api_key
        self._model = model
        self._max_retry_attempts = max_retry_attempts
        self._owns_client = http_client is None
        self._client = http_client or httpx.AsyncClient(
            base_url=base_url, timeout=httpx.Timeout(timeout_seconds)
        )

    async def aclose(self) -> None:
        if self._owns_client:
            await self._client.aclose()

    async def __aenter__(self) -> Self:
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        await self.aclose()

    async def generate_structured_json(
        self,
        *,
        system_instruction: str,
        user_content: str,
        response_schema: dict[str, Any],
        temperature: float = 0.2,
        model: str | None = None,
    ) -> GeminiGenerationResult:
        """Pide a Gemini una respuesta forzada a `response_schema` (JSON mode). Devuelve el
        texto crudo sin parsear — el llamador (Nodo 3) valida contra su propio modelo de
        dominio. Cualquier fallo de red, respuesta sin candidatos, o `finish_reason` distinto
        de STOP (ej. SAFETY, MAX_TOKENS) se traduce a `status=ERROR_API` con
        `raw_json_text=None`, nunca a una respuesta inventada.
        """

        target_model = model or self._model
        path = f"/models/{target_model}:generateContent"
        generated_at = datetime.now(timezone.utc)

        body = {
            "system_instruction": {"parts": [{"text": system_instruction}]},
            "contents": [{"role": "user", "parts": [{"text": user_content}]}],
            "generationConfig": {
                "responseMimeType": "application/json",
                "responseSchema": response_schema,
                "temperature": temperature,
            },
        }

        try:
            response = await request_with_retries(
                self._client,
                "POST",
                path,
                provider=_PROVIDER_NAME,
                max_attempts=self._max_retry_attempts,
                params={"key": self._api_key},
                json=body,
            )
        except (
            ProviderTimeoutError,
            ProviderRateLimitError,
            ProviderAuthenticationError,
            ProviderResponseError,
        ) as exc:
            logger.warning(
                "gemini_request_failed",
                extra={"model": target_model, "error": str(exc)},
            )
            return GeminiGenerationResult(
                status=DataStatus.ERROR_API,
                raw_json_text=None,
                finish_reason=None,
                model=target_model,
                generated_at=generated_at,
            )

        try:
            payload = response.json()
        except ValueError:
            return GeminiGenerationResult(
                status=DataStatus.ERROR_API,
                raw_json_text=None,
                finish_reason=None,
                model=target_model,
                generated_at=generated_at,
            )

        text, finish_reason = _extract_candidate_text(payload)

        if text is None or finish_reason not in (None, "STOP"):
            logger.warning(
                "gemini_generation_incomplete",
                extra={"model": target_model, "finish_reason": finish_reason},
            )
            return GeminiGenerationResult(
                status=DataStatus.ERROR_API,
                raw_json_text=None,
                finish_reason=finish_reason,
                model=target_model,
                generated_at=generated_at,
            )

        return GeminiGenerationResult(
            status=DataStatus.OK,
            raw_json_text=text,
            finish_reason=finish_reason,
            model=target_model,
            generated_at=generated_at,
        )


def _extract_candidate_text(payload: Any) -> tuple[str | None, str | None]:
    if not isinstance(payload, dict):
        return None, None

    candidates = payload.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        return None, None

    first = candidates[0]
    if not isinstance(first, dict):
        return None, None

    finish_reason = first.get("finishReason")
    finish_reason = finish_reason if isinstance(finish_reason, str) else None

    content = first.get("content")
    parts = content.get("parts") if isinstance(content, dict) else None
    if not isinstance(parts, list) or not parts or not isinstance(parts[0], dict):
        return None, finish_reason

    text = parts[0].get("text")
    return (text if isinstance(text, str) else None), finish_reason
