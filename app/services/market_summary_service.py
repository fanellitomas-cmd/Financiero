"""Servicio de `GET /api/v1/market/summary`: compila el estado de la jornada (mayores alzas y
bajas de NASDAQ/NYSE) y le pide a Gemini un resumen ejecutivo, con caché en memoria para no
gastar una llamada al modelo por cada usuario que abre el Dashboard.

Dos degradaciones independientes, deliberadamente separadas (.cursorrules §2):
  - Sin datos de mercado (Polygon caído o devolviendo vacío) → `market_data_available=False` y
    listas vacías. No se invoca al modelo: pedirle un resumen sin datos es pedirle que invente.
  - Sin Gemini configurado o con Gemini fallando → los movers se sirven igual y solo la parte
    narrativa queda en `None`, con `ai_narrative_available=False` y un `degradation_reason`
    legible. El Dashboard sigue mostrando algo útil.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.enums import ExchangeType
from app.models.ticker import Ticker
from app.schemas.market import (
    MarketMoverOut,
    MarketSentiment,
    MarketSummary,
)
from src.ingestion.gemini_client import GeminiClient
from src.ingestion.polygon_client import MoverDirection, PolygonClient
from src.ingestion.schemas_raw import MarketMover
from src.validation.domain_models import DataStatus, MetricValue

logger = logging.getLogger(__name__)

_PROMPT_PATH = (
    Path(__file__).resolve().parent.parent.parent
    / "prompts"
    / "market_summary_system_prompt.md"
)

_RESPONSE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "headline": {"type": "string"},
        "key_points": {"type": "array", "items": {"type": "string"}},
        "sentiment_label": {
            "type": "string",
            "enum": ["ALCISTA", "NEUTRAL", "BAJISTA"],
        },
        "sentiment_confidence_pct": {"type": "number"},
    },
    "required": ["headline", "key_points", "sentiment_label"],
}

_SENTIMENT_LABELS = frozenset({"ALCISTA", "NEUTRAL", "BAJISTA"})

# Bolsas que el producto ofrece hoy. `ExchangeType.OTHER` queda afuera a propósito: un mover de
# una bolsa que la app no soporta no le sirve a nadie en el Dashboard.
_OFFERED_EXCHANGES: tuple[ExchangeType, ...] = (
    ExchangeType.NASDAQ,
    ExchangeType.NYSE,
)

_REASON_NO_GEMINI = (
    "El resumen con IA no está configurado en este entorno (falta GEMINI_API_KEY en .env); "
    "se muestran las alzas y bajas sin narrativa."
)
_REASON_NO_MARKET_DATA = (
    "No hay datos de alzas y bajas de la jornada en este momento (el proveedor de precios no "
    "devolvió resultados)."
)
_REASON_GEMINI_FAILED = (
    "No se pudo generar el resumen con IA en este momento (falló la consulta al modelo); "
    "las alzas y bajas son datos reales."
)
_REASON_GEMINI_INVALID = (
    "El modelo devolvió un resumen que no se pudo interpretar; las alzas y bajas son datos "
    "reales."
)


class _LLMSummaryOutput(BaseModel):
    """Forma exacta de lo que se le pide al LLM. Solo la narrativa: los movers, la bolsa y el
    timestamp los fija el código a partir de los datos del proveedor, nunca el modelo.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    headline: str
    key_points: list[str] = Field(default_factory=list)
    sentiment_label: str
    sentiment_confidence_pct: float | None = None


def _load_system_prompt() -> str:
    try:
        return _PROMPT_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(
            f"No se pudo leer el system prompt del resumen de mercado en {_PROMPT_PATH}."
        ) from exc


def _as_float(metric: MetricValue) -> float | None:
    """Convierte un `MetricValue` al float que expone la API, o `None` si el proveedor no mandó
    el dato. Toma el `MetricValue` y no `(objeto, nombre_de_campo)`: un `getattr` por string le
    saca el tipo al valor y un typo en el nombre solo se vería en runtime.
    """

    if metric.value is None or metric.status != DataStatus.OK:
        return None
    return float(metric.value)


class MarketSummaryService:
    """`gemini_client=None` es un estado válido y esperado, no un error: significa "este entorno
    no tiene el modelo configurado". El servicio se construye igual y sirve los datos duros.
    """

    def __init__(
        self,
        polygon_client: PolygonClient,
        session_factory: async_sessionmaker[AsyncSession],
        *,
        gemini_client: GeminiClient | None = None,
        cache_ttl_seconds: float = 900.0,
        movers_per_direction: int = 5,
        system_prompt: str | None = None,
    ) -> None:
        self._polygon = polygon_client
        self._session_factory = session_factory
        self._gemini = gemini_client
        self._cache_ttl_seconds = cache_ttl_seconds
        self._movers_per_direction = movers_per_direction
        self._system_prompt = system_prompt or _load_system_prompt()

        self._cached: MarketSummary | None = None
        self._cached_at_monotonic: float | None = None
        # Un solo lock para toda la clase: sin él, N usuarios abriendo el Dashboard a la vez con
        # la caché vencida disparan N llamadas a Gemini en paralelo — exactamente lo que la
        # caché existe para evitar. Con el lock, el primero la refresca y el resto espera y lee
        # el resultado ya cacheado.
        self._refresh_lock = asyncio.Lock()

    async def get_summary(self, *, force_refresh: bool = False) -> MarketSummary:
        if not force_refresh:
            cached = self._fresh_cache()
            if cached is not None:
                return cached

        async with self._refresh_lock:
            # Re-chequeo adentro del lock: mientras se esperaba, otra corrida pudo haberla
            # refrescado, y en ese caso volver a pegarle al modelo sería justamente el gasto
            # que se quiere evitar.
            if not force_refresh:
                cached = self._fresh_cache()
                if cached is not None:
                    return cached

            summary = await self._build_summary()
            self._cached = summary
            self._cached_at_monotonic = time.monotonic()
            return summary

    def _fresh_cache(self) -> MarketSummary | None:
        """`time.monotonic` y no `datetime.now`: la caché mide tiempo transcurrido, y un ajuste
        de reloj del sistema (NTP, cambio de horario) no debería invalidarla ni eternizarla.
        """

        if self._cached is None or self._cached_at_monotonic is None:
            return None
        if time.monotonic() - self._cached_at_monotonic > self._cache_ttl_seconds:
            return None
        return self._cached.model_copy(update={"served_from_cache": True})

    async def _build_summary(self) -> MarketSummary:
        gainers, losers = await asyncio.gather(
            self._polygon.get_market_movers(MoverDirection.GAINERS),
            self._polygon.get_market_movers(MoverDirection.LOSERS),
        )

        top_gainers, top_losers = await self._enrich_and_filter(gainers, losers)
        has_market_data = bool(top_gainers or top_losers)

        # La narrativa se resuelve primero y el modelo se construye UNA vez con todo, en vez de
        # ir pisando campos con `model_copy`: `MarketSummary` es strict y frozen, y `model_copy`
        # saltea la validación — armarlo de una deja que Pydantic verifique el resultado final.
        narrative: _LLMSummaryOutput | None = None
        reason: str | None = None

        if not has_market_data:
            logger.warning("market_summary_no_movers")
            reason = _REASON_NO_MARKET_DATA
        elif (gemini := self._gemini) is None:
            reason = _REASON_NO_GEMINI
        else:
            # Devuelve la narrativa o el motivo de la degradación, nunca lanza.
            result = await self._generate_narrative(gemini, top_gainers, top_losers)
            if isinstance(result, str):
                reason = result
            else:
                narrative = result

        return MarketSummary(
            generated_at=datetime.now(timezone.utc),
            exchanges=list(_OFFERED_EXCHANGES),
            top_gainers=top_gainers,
            top_losers=top_losers,
            market_data_available=has_market_data,
            headline=narrative.headline if narrative is not None else None,
            key_points=narrative.key_points if narrative is not None else [],
            sentiment=MarketSentiment(
                label=narrative.sentiment_label,
                confidence_pct=narrative.sentiment_confidence_pct,
            )
            if narrative is not None
            else None,
            ai_narrative_available=narrative is not None,
            degradation_reason=reason,
        )

    async def _enrich_and_filter(
        self, gainers: list[MarketMover], losers: list[MarketMover]
    ) -> tuple[list[MarketMoverOut], list[MarketMoverOut]]:
        """Cruza los movers con el catálogo local para saber en qué bolsa cotiza cada uno y
        quedarse solo con NASDAQ/NYSE.

        Una sola consulta para los dos lados (no una por ticker): son ~40 símbolos entre alzas y
        bajas y hacer 40 SELECTs por request sería gratis de escribir y caro de correr.

        Un símbolo que no está en el catálogo se descarta en vez de mostrarse sin bolsa: acá el
        contrato del endpoint es "alzas y bajas de NASDAQ/NYSE", y no poder afirmar la bolsa de
        un símbolo es no poder afirmar que cumple el filtro. (Distinto de `WatchlistItem`, donde
        el usuario eligió ese ticker explícitamente y esconderlo sería perderle un dato propio.)
        """

        symbols = {mover.ticker for mover in gainers} | {
            mover.ticker for mover in losers
        }
        if not symbols:
            return [], []

        async with self._session_factory() as session:
            rows = (
                await session.execute(
                    select(Ticker.symbol, Ticker.name, Ticker.exchange).where(
                        Ticker.symbol.in_(symbols),
                        Ticker.exchange.in_(_OFFERED_EXCHANGES),
                    )
                )
            ).all()

        catalog = {symbol: (name, exchange) for symbol, name, exchange in rows}

        def convert(
            movers: list[MarketMover], *, descending: bool
        ) -> list[MarketMoverOut]:
            matched: list[MarketMoverOut] = []
            for mover in movers:
                entry = catalog.get(mover.ticker)
                if entry is None:
                    continue
                name, exchange = entry
                matched.append(
                    MarketMoverOut(
                        ticker=mover.ticker,
                        name=name,
                        exchange=exchange,
                        last_price=_as_float(mover.last_price),
                        day_change_pct=_as_float(mover.day_change_pct),
                    )
                )

            # Se reordena en vez de confiar en el orden del proveedor. Polygon devuelve los movers
            # ya ordenados, pero ese contrato no se pudo verificar en vivo (ver la nota en
            # `polygon_client.py`) y acá el orden no es cosmético: recortar a
            # `movers_per_direction` sobre una lista mal ordenada daría "los 5 primeros" en vez
            # de "los 5 mayores".
            def sort_key(mover: MarketMoverOut) -> tuple[int, float]:
                # Sin variación no se puede rankear: esos van al final (primer elemento en 1).
                if mover.day_change_pct is None:
                    return (1, 0.0)
                return (
                    0,
                    -mover.day_change_pct if descending else mover.day_change_pct,
                )

            matched.sort(key=sort_key)
            return matched[: self._movers_per_direction]

        return convert(gainers, descending=True), convert(losers, descending=False)

    async def _generate_narrative(
        self,
        gemini: GeminiClient,
        gainers: list[MarketMoverOut],
        losers: list[MarketMoverOut],
    ) -> _LLMSummaryOutput | str:
        """Devuelve la narrativa, o un motivo de degradación (string) si no se pudo obtener —
        el llamador decide qué hacer con eso. Nunca lanza: un fallo del modelo no debe tumbar
        un endpoint cuyos datos duros ya están listos.

        El cliente llega por parámetro y no se lee de `self._gemini`: el llamador ya lo estrechó
        a no-None, y pasarlo evita un `assert` que `python -O` borraría.
        """

        result = await gemini.generate_structured_json(
            system_instruction=self._system_prompt,
            user_content=_build_market_context(gainers, losers),
            response_schema=_RESPONSE_SCHEMA,
        )

        if result.status != DataStatus.OK or result.raw_json_text is None:
            logger.warning("market_summary_gemini_call_failed")
            return _REASON_GEMINI_FAILED

        try:
            parsed = json.loads(result.raw_json_text)
            # strict=False solo en esta frontera JSON, mismo caso que `chat_service.py` y
            # `scenario_evaluator.py`: JSON no tiene tipo nativo para Decimal ni Enum.
            output = _LLMSummaryOutput.model_validate(parsed, strict=False)
        except (json.JSONDecodeError, ValidationError) as exc:
            logger.warning("market_summary_output_invalid", extra={"error": str(exc)})
            return _REASON_GEMINI_INVALID

        if output.sentiment_label.upper() not in _SENTIMENT_LABELS:
            # El `response_schema` ya declara el enum, pero no se confía en que el proveedor lo
            # respete: un label libre llegaría hasta la UI y rompería el pintado por sentimiento.
            logger.warning(
                "market_summary_sentiment_label_unexpected",
                extra={"label": output.sentiment_label},
            )
            return _REASON_GEMINI_INVALID

        return output.model_copy(
            update={"sentiment_label": output.sentiment_label.upper()}
        )


def _format_movers(movers: list[MarketMoverOut]) -> str:
    if not movers:
        return "  (sin datos)"
    lines = []
    for mover in movers:
        change = (
            f"{mover.day_change_pct:+.2f}%"
            if mover.day_change_pct is not None
            else "variación no disponible"
        )
        price = (
            f"USD {mover.last_price:.2f}"
            if mover.last_price is not None
            else "precio no disponible"
        )
        exchange = mover.exchange.value if mover.exchange is not None else "?"
        lines.append(f"  - {mover.ticker} ({exchange}): {change}, {price}")
    return "\n".join(lines)


def _build_market_context(
    gainers: list[MarketMoverOut], losers: list[MarketMoverOut]
) -> str:
    """Arma el `<market_data>` que el prompt exige como única fuente. Texto plano tabulado y no
    JSON crudo a propósito: el modelo tiene que leer variaciones y compararlas, y este formato
    deja menos margen para que confunda un campo con otro.
    """

    return (
        "<market_data>\n"
        f"Bolsas cubiertas: {', '.join(exchange.value for exchange in _OFFERED_EXCHANGES)}\n"
        "Mayores alzas de la jornada:\n"
        f"{_format_movers(gainers)}\n"
        "Mayores bajas de la jornada:\n"
        f"{_format_movers(losers)}\n"
        "</market_data>"
    )
