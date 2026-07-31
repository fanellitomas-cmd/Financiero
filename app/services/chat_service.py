"""Servicio de `POST /api/v1/chat`: arma el contexto financiero disponible (el último
`AlertHistory` persistido para el ticker mencionado, si existe) y se lo pasa a Gemini con
salida forzada a JSON — mismo patrón que ya usa el Nodo 3 (`src/processing/scenario_evaluator.py`),
nunca texto libre sin validar contra un `response_schema`.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any

from pydantic import BaseModel, ConfigDict, ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.alert_history import AlertHistory
from app.schemas.chat import ChatResponse
from src.ingestion.gemini_client import GeminiClient
from src.validation.domain_models import DataStatus

logger = logging.getLogger(__name__)

_PROMPT_PATH = (
    Path(__file__).resolve().parent.parent.parent
    / "prompts"
    / "chat_assistant_system_prompt.md"
)

_RESPONSE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {"reply": {"type": "string"}},
    "required": ["reply"],
}

_FALLBACK_REPLY_ON_PROVIDER_ERROR = (
    "No pude generar una respuesta en este momento (falló la consulta al modelo). "
    "Probá de nuevo en un rato."
)
_FALLBACK_REPLY_ON_INVALID_OUTPUT = (
    "No pude interpretar la respuesta del modelo. Probá reformular la pregunta."
)


class _LLMChatOutput(BaseModel):
    """Forma exacta de lo que le pedimos al LLM — deliberadamente solo `reply`:
    `referenced_ticker`/`grounded_in_recent_alert` los fija el código a partir del request,
    no el modelo (evita que el LLM "invente" a qué ticker se refirió).
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    reply: str


def _load_system_prompt() -> str:
    try:
        return _PROMPT_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(
            f"No se pudo leer el system prompt del chat en {_PROMPT_PATH}."
        ) from exc


class ChatService:
    def __init__(
        self,
        gemini_client: GeminiClient,
        session_factory: async_sessionmaker[AsyncSession],
        *,
        system_prompt: str | None = None,
    ) -> None:
        self._gemini = gemini_client
        self._session_factory = session_factory
        self._system_prompt = system_prompt or _load_system_prompt()

    async def answer(self, prompt: str, ticker: str | None) -> ChatResponse:
        normalized_ticker = ticker.upper() if ticker else None
        context = (
            await self._recent_context(normalized_ticker) if normalized_ticker else None
        )
        user_content = self._build_user_content(prompt, normalized_ticker, context)

        result = await self._gemini.generate_structured_json(
            system_instruction=self._system_prompt,
            user_content=user_content,
            response_schema=_RESPONSE_SCHEMA,
        )

        if result.status != DataStatus.OK or result.raw_json_text is None:
            logger.warning(
                "chat_gemini_call_failed", extra={"ticker": normalized_ticker}
            )
            return ChatResponse(
                reply=_FALLBACK_REPLY_ON_PROVIDER_ERROR,
                referenced_ticker=normalized_ticker,
                grounded_in_recent_alert=False,
            )

        try:
            parsed = json.loads(result.raw_json_text)
            # strict=False solo en esta frontera JSON, mismo caso que en
            # scenario_evaluator.py: el resto del código sigue en modo strict.
            llm_output = _LLMChatOutput.model_validate(parsed, strict=False)
        except (json.JSONDecodeError, ValidationError) as exc:
            logger.warning(
                "chat_output_invalid",
                extra={"ticker": normalized_ticker, "error": str(exc)},
            )
            return ChatResponse(
                reply=_FALLBACK_REPLY_ON_INVALID_OUTPUT,
                referenced_ticker=normalized_ticker,
                grounded_in_recent_alert=False,
            )

        return ChatResponse(
            reply=llm_output.reply,
            referenced_ticker=normalized_ticker,
            grounded_in_recent_alert=context is not None,
        )

    async def _recent_context(self, ticker: str) -> str | None:
        async with self._session_factory() as session:
            row = await session.scalar(
                select(AlertHistory)
                .where(AlertHistory.ticker == ticker)
                .order_by(AlertHistory.created_at.desc())
                .limit(1)
            )
        if row is None:
            return None
        return json.dumps(row.payload_json, ensure_ascii=False)

    def _build_user_content(
        self, prompt: str, ticker: str | None, context: str | None
    ) -> str:
        if ticker is None:
            return f"<user_prompt>{prompt}</user_prompt>\n<context>No se especificó un ticker.</context>"
        if context is None:
            return (
                f"<user_prompt>{prompt}</user_prompt>\n"
                f"<ticker>{ticker}</ticker>\n"
                "<context>No hay un análisis reciente guardado para este ticker.</context>"
            )
        return (
            f"<user_prompt>{prompt}</user_prompt>\n"
            f"<ticker>{ticker}</ticker>\n"
            f"<context>{context}</context>"
        )
