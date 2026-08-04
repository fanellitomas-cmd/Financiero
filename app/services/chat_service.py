"""Servicio de `POST /api/v1/chat`: arma el contexto financiero disponible y se lo pasa a Gemini
con salida forzada a JSON — mismo patrón que ya usa el Nodo 3
(`src/processing/scenario_evaluator.py`), nunca texto libre sin validar contra un
`response_schema`.

El contexto se construye dinámicamente según lo que la pregunta traiga:
  - **Con ticker:** cotización en vivo (precio y % del día vía `MarketDataService`), la bolsa
    según el catálogo local, y el último `AlertHistory` persistido si existe.
  - **Sin ticker:** estado general del mercado (mayores alzas y bajas de la jornada, ya
    filtradas por bolsa) reusando la caché de `MarketSummaryService` — la misma que sirve
    `GET /api/v1/market/summary`, así una pregunta general no gasta una llamada extra al
    proveedor.

Las tres fuentes son opcionales por separado: si Polygon no está configurado el chat sigue
funcionando con lo que haya en la DB, y cada bloque ausente se declara explícitamente en el
prompt para que el modelo diga "no tengo ese dato" en vez de inventarlo (.cursorrules §2).
"""

from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any, Protocol

from pydantic import BaseModel, ConfigDict, ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.alert_history import AlertHistory
from app.models.enums import AssetType
from app.models.ticker import Ticker
from app.schemas.chat import ChatResponse
from app.schemas.market import MarketSummary, TickerQuote
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


class QuoteProviderLike(Protocol):
    """Lo único que el chat necesita de `MarketDataService`. Protocol y no la clase concreta para
    que los tests puedan pasar un doble sin heredar de un servicio que envuelve un cliente HTTP.
    """

    async def get_quotes(
        self, items: list[tuple[str, AssetType]]
    ) -> list[TickerQuote]: ...


class MarketSummaryLike(Protocol):
    """Lo único que el chat necesita del resumen de mercado, para el contexto general."""

    async def get_summary(self, *, force_refresh: bool = False) -> MarketSummary: ...


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
        quote_provider: QuoteProviderLike | None = None,
        market_summary: MarketSummaryLike | None = None,
    ) -> None:
        self._gemini = gemini_client
        self._session_factory = session_factory
        self._system_prompt = system_prompt or _load_system_prompt()
        self._quote_provider = quote_provider
        self._market_summary = market_summary

    async def answer(self, prompt: str, ticker: str | None) -> ChatResponse:
        normalized_ticker = ticker.upper() if ticker else None

        if normalized_ticker is None:
            user_content = await self._build_general_content(prompt)
            alert_context: str | None = None
        else:
            alert_context = await self._recent_context(normalized_ticker)
            user_content = await self._build_ticker_content(
                prompt, normalized_ticker, alert_context
            )

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
            grounded_in_recent_alert=alert_context is not None,
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

    async def _live_quote_block(self, ticker: str) -> str:
        """Cotización en vivo del ticker, o una línea explícita diciendo que no hay.

        El `asset_type` se decide por la forma del símbolo (`BTC-USD` → cripto) porque el chat
        recibe un ticker suelto, sin el `asset_type` que sí pide `GET /api/v1/assets/{ticker}`:
        pedirlo en el body del chat obligaría al cliente a saberlo antes de preguntar.
        """

        if self._quote_provider is None:
            return "<live_quote>Los precios en vivo no están configurados en este entorno.</live_quote>"

        asset_type = AssetType.CRYPTO if "-" in ticker else AssetType.STOCK
        try:
            quotes = await self._quote_provider.get_quotes([(ticker, asset_type)])
        except Exception as exc:  # noqa: BLE001 — un proveedor caído no debe tumbar el chat:
            # se degrada ese bloque del contexto y se registra explícito (.cursorrules §2).
            logger.warning(
                "chat_live_quote_failed", extra={"ticker": ticker, "error": str(exc)}
            )
            return "<live_quote>No se pudo obtener la cotización en vivo.</live_quote>"

        if not quotes or quotes[0].status != DataStatus.OK:
            return f"<live_quote>Sin cotización disponible para {ticker} ahora mismo.</live_quote>"

        quote = quotes[0]
        price = (
            f"USD {quote.last_price:.4f}"
            if quote.last_price is not None
            else "no disponible"
        )
        change = (
            f"{quote.day_change_pct:+.2f}%"
            if quote.day_change_pct is not None
            else "no disponible"
        )
        return (
            "<live_quote>"
            f"Último precio: {price}. Variación del día: {change}."
            "</live_quote>"
        )

    async def _exchange_block(self, ticker: str) -> str:
        """Bolsa del ticker según el catálogo local. No pasa por `TickerCatalogService` para no
        agregarle una dependencia más al chat: es un único SELECT sobre el mismo session factory
        que ya tiene, y además acá se necesita el nombre de la empresa, que `find_exchange` no
        devuelve.
        """

        async with self._session_factory() as session:
            row = (
                await session.execute(
                    select(Ticker.name, Ticker.exchange).where(Ticker.symbol == ticker)
                )
            ).first()

        if row is None:
            return "<exchange>Este símbolo no está en el catálogo local, así que no se puede afirmar en qué bolsa cotiza.</exchange>"
        name, exchange = row
        return f"<exchange>{name} cotiza en {exchange.value}.</exchange>"

    async def _build_ticker_content(
        self, prompt: str, ticker: str, alert_context: str | None
    ) -> str:
        live_quote = await self._live_quote_block(ticker)
        exchange = await self._exchange_block(ticker)
        analysis = (
            f"<recent_analysis>{alert_context}</recent_analysis>"
            if alert_context is not None
            else "<recent_analysis>No hay un análisis reciente guardado para este ticker.</recent_analysis>"
        )

        return (
            f"<user_prompt>{prompt}</user_prompt>\n"
            f"<ticker>{ticker}</ticker>\n"
            f"{exchange}\n"
            f"{live_quote}\n"
            f"{analysis}"
        )

    async def _build_general_content(self, prompt: str) -> str:
        """Sin ticker el contexto es el estado general del mercado. Se lee de la caché del
        resumen (`MarketSummaryService`), así una pregunta general no dispara una llamada nueva
        al proveedor por cada mensaje del chat.
        """

        if self._market_summary is None:
            return (
                f"<user_prompt>{prompt}</user_prompt>\n"
                "<market_context>No se especificó un ticker y no hay datos de mercado "
                "disponibles en este entorno.</market_context>"
            )

        try:
            summary = await self._market_summary.get_summary()
        except Exception as exc:  # noqa: BLE001 — igual que en `_live_quote_block`: el chat
            # responde sin contexto de mercado antes que fallar entero.
            logger.warning("chat_market_context_failed", extra={"error": str(exc)})
            return (
                f"<user_prompt>{prompt}</user_prompt>\n"
                "<market_context>No se pudo obtener el estado del mercado.</market_context>"
            )

        if not summary.market_data_available:
            return (
                f"<user_prompt>{prompt}</user_prompt>\n"
                "<market_context>No hay datos de alzas y bajas de la jornada en este "
                "momento.</market_context>"
            )

        return (
            f"<user_prompt>{prompt}</user_prompt>\n"
            f"<market_context>\n{_summary_as_context(summary)}\n</market_context>"
        )


def _summary_as_context(summary: MarketSummary) -> str:
    def line(label: str, movers: list[Any]) -> str:
        if not movers:
            return f"{label}: sin datos."
        parts = [
            f"{mover.ticker} "
            + (
                f"({mover.day_change_pct:+.2f}%)"
                if mover.day_change_pct is not None
                else "(variación no disponible)"
            )
            for mover in movers
        ]
        return f"{label}: {', '.join(parts)}."

    blocks = [
        line("Mayores alzas de la jornada", summary.top_gainers),
        line("Mayores bajas de la jornada", summary.top_losers),
    ]
    if summary.headline is not None:
        blocks.append(f"Resumen de la jornada: {summary.headline}")
    return "\n".join(blocks)
