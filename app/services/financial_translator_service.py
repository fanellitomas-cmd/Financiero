"""Servicio de `POST /api/v1/ai/translate-financial` — el Traductor Financiero.

Reescribe un término o un análisis técnico en castellano llano, con una analogía cotidiana y un
glosario de los tecnicismos que aparecían.

Dos cosas lo distinguen del resto de los servicios que consumen al modelo:

  - **No hay datos que alucinar, y por eso la regla es otra.** El material es el texto que el
    usuario mandó, así que el riesgo no es inventar un número: es *agregar* una conclusión que el
    texto original no tenía ("esto significa que va a subir"). El prompt lo prohíbe explícitamente
    y el servicio no le da al modelo ninguna fuente de datos de mercado, justamente para que no
    tenga con qué.
  - **La caché es por contenido, no por usuario.** Traducir "P/E de 58x" da lo mismo para
    cualquiera que lo pida, así que la clave es el hash del texto más el contexto. Es la operación
    con más chance de repetirse del sistema: el mismo término aparece en la Ficha de todos los que
    miran ese activo.
"""

from __future__ import annotations

import hashlib
import json
import logging
import time
from pathlib import Path
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from app.schemas.translation import FinancialTranslation, GlossaryEntry
from src.ingestion.gemini_client import GeminiClient
from src.validation.domain_models import DataStatus

logger = logging.getLogger(__name__)

_PROMPT_PATH = (
    Path(__file__).resolve().parent.parent.parent
    / "prompts"
    / "financial_translator_system_prompt.md"
)

_REASON_NO_GEMINI = "El Traductor Financiero no está configurado en este entorno (falta GEMINI_API_KEY en .env)."
_REASON_GEMINI_FAILED = (
    "No se pudo traducir el texto en este momento (falló la consulta al modelo). Probá de nuevo "
    "en un rato."
)
_REASON_GEMINI_INVALID = "El modelo devolvió una explicación que no se pudo interpretar. Probá con un texto más corto."

_RESPONSE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "simple_explanation": {"type": "string"},
        "analogy": {"type": "string"},
        "key_terms": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "term": {"type": "string"},
                    "plain_meaning": {"type": "string"},
                },
                "required": ["term", "plain_meaning"],
            },
        },
    },
    "required": ["simple_explanation"],
}

# Tope de entradas en caché. Cada una son unos pocos KB, así que 500 es del orden de un par de MB
# y cubre de sobra los términos que se repiten. Sin tope, un cliente que traduzca textos siempre
# distintos haría crecer el diccionario sin límite mientras el proceso viva.
_MAX_CACHE_ENTRIES = 500


def _load_system_prompt() -> str:
    try:
        return _PROMPT_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(
            f"No se pudo leer el system prompt del Traductor Financiero en {_PROMPT_PATH}."
        ) from exc


class _LLMGlossaryEntry(BaseModel):
    model_config = ConfigDict(strict=True, extra="ignore")

    term: str
    plain_meaning: str


class _LLMTranslation(BaseModel):
    """Forma exacta de lo que se le pide al modelo.

    `analogy` y `key_terms` son opcionales a propósito: para un párrafo corto o para un término que
    no tiene equivalente cotidiano, forzar una analogía produce una peor que ninguna.
    """

    model_config = ConfigDict(strict=True, extra="ignore")

    simple_explanation: str
    analogy: str | None = None
    key_terms: list[_LLMGlossaryEntry] = Field(default_factory=list)


class FinancialTranslatorService:
    """`gemini_client=None` es un estado válido y esperado: el servicio se instancia igual y
    devuelve `available=False` con el motivo. El cliente muestra el aviso en línea en vez de
    tratar una ayuda opcional como una falla de la pantalla.
    """

    def __init__(
        self,
        *,
        gemini_client: GeminiClient | None = None,
        cache_ttl_seconds: float = 86400.0,
        max_cache_entries: int = _MAX_CACHE_ENTRIES,
        system_prompt: str | None = None,
    ) -> None:
        self._gemini = gemini_client
        self._cache_ttl_seconds = cache_ttl_seconds
        self._max_cache_entries = max_cache_entries
        self._system_prompt = system_prompt or _load_system_prompt()
        self._cache: dict[str, tuple[float, FinancialTranslation]] = {}

    async def translate(
        self, text: str, *, context: str | None = None
    ) -> FinancialTranslation:
        if (gemini := self._gemini) is None:
            return FinancialTranslation(
                original_text=text,
                available=False,
                degradation_reason=_REASON_NO_GEMINI,
            )

        key = _cache_key(text, context)
        cached = self._fresh_cache(key)
        if cached is not None:
            return cached

        result = await gemini.generate_structured_json(
            system_instruction=self._system_prompt,
            user_content=_build_user_content(text, context),
            response_schema=_RESPONSE_SCHEMA,
        )

        if result.status != DataStatus.OK or result.raw_json_text is None:
            logger.warning("translate_financial_gemini_call_failed")
            return FinancialTranslation(
                original_text=text,
                available=False,
                degradation_reason=_REASON_GEMINI_FAILED,
            )

        try:
            parsed = json.loads(result.raw_json_text)
            # strict=False solo en esta frontera JSON, mismo caso que el resto de los servicios que
            # consumen al modelo.
            output = _LLMTranslation.model_validate(parsed, strict=False)
        except (json.JSONDecodeError, ValidationError) as exc:
            logger.warning(
                "translate_financial_output_invalid", extra={"error": str(exc)}
            )
            return FinancialTranslation(
                original_text=text,
                available=False,
                degradation_reason=_REASON_GEMINI_INVALID,
            )

        explanation = output.simple_explanation.strip()
        if not explanation:
            # Una explicación vacía es una respuesta fallida con forma válida: se trata como
            # inválida en vez de devolver `available=True` con el campo en blanco.
            return FinancialTranslation(
                original_text=text,
                available=False,
                degradation_reason=_REASON_GEMINI_INVALID,
            )

        analogy = (output.analogy or "").strip() or None
        translation = FinancialTranslation(
            original_text=text,
            simple_explanation=explanation,
            analogy=analogy,
            key_terms=[
                GlossaryEntry(
                    term=entry.term.strip(),
                    plain_meaning=entry.plain_meaning.strip(),
                )
                for entry in output.key_terms
                if entry.term.strip() and entry.plain_meaning.strip()
            ],
            available=True,
        )
        self._store(key, translation)
        return translation

    def _fresh_cache(self, key: str) -> FinancialTranslation | None:
        """`time.monotonic` y no `datetime.now`: la caché mide tiempo transcurrido, y un ajuste de
        reloj del sistema no debería invalidarla ni eternizarla.
        """

        entry = self._cache.get(key)
        if entry is None:
            return None
        cached_at, value = entry
        if time.monotonic() - cached_at > self._cache_ttl_seconds:
            del self._cache[key]
            return None
        return value.model_copy(update={"served_from_cache": True})

    def _store(self, key: str, translation: FinancialTranslation) -> None:
        # Desalojo por orden de inserción (los `dict` de Python lo preservan): se tira la más vieja
        # cuando se llena. No es un LRU —una entrada muy consultada igual envejece— pero acá el
        # costo de un miss es una llamada al modelo, no una inconsistencia, y un LRU real pediría
        # estructura extra para un beneficio marginal.
        if len(self._cache) >= self._max_cache_entries:
            oldest = next(iter(self._cache))
            del self._cache[oldest]
        self._cache[key] = (time.monotonic(), translation)


def _cache_key(text: str, context: str | None) -> str:
    """Hash del contenido, no el texto crudo: las claves pueden ser párrafos de 4000 caracteres y
    guardarlos duplicaría en memoria todo lo cacheado.

    El contexto entra en la clave porque cambia la respuesta: el mismo término explicado sobre una
    tecnológica y sobre un banco no da lo mismo.
    """

    digest = hashlib.sha256()
    digest.update(text.strip().encode("utf-8"))
    digest.update(b"\x00")
    digest.update((context or "").strip().encode("utf-8"))
    return digest.hexdigest()


def _build_user_content(text: str, context: str | None) -> str:
    """Arma el bloque que el prompt exige. El contexto va en su propia etiqueta y se declara
    explícitamente cuando falta: si el bloque no apareciera, el modelo no tendría cómo saber que no
    hay contexto y podría suponer uno.
    """

    context_block = (context or "").strip() or "(sin contexto adicional)"
    return (
        "<texto_original>\n"
        f"{text.strip()}\n"
        "</texto_original>\n"
        "<contexto>\n"
        f"{context_block}\n"
        "</contexto>"
    )
