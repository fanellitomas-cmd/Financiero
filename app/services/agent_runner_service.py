"""Orquesta la ejecución del pipeline de LangGraph (`src/`) sobre los tickers activos en
`Watchlists`, invocado por el Cron/Scheduler externo vía `POST /internal/trigger-agent`.

Corre el grafo UNA vez por ticker (no una vez por usuario): el `PushNotificationPayload` que
produce el Nodo 5 ya incluye ambas narrativas (técnica y principiante, ver
`src/notification/payload_builder.py`), así que la preferencia `enable_beginner_mode` de cada
usuario se resuelve del lado del cliente/push, no re-corriendo el análisis por usuario.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from langgraph.graph.state import CompiledStateGraph
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.alert_history import AlertHistory
from app.models.enums import AssetType
from app.models.watchlist import WatchlistItem
from app.schemas.alert import TickerRunResult
from app.services.push_service import PushNotificationService
from src.core.dependencies import GraphDependencies
from src.core.state import AgentState
from src.processing.graph import build_graph
from src.validation.domain_models import (
    AssetClass,
    MarketAlert,
    PushNotificationPayload,
    UserProfile,
    WatchedAsset,
)

logger = logging.getLogger(__name__)

_ASSET_TYPE_TO_ASSET_CLASS = {
    AssetType.STOCK: AssetClass.EQUITY,
    AssetType.CRYPTO: AssetClass.CRYPTO,
}


class AssetIntelligenceUnavailableError(Exception):
    """El motor corrió pero no produjo un `PushNotificationPayload` (ej. no se detectó
    ningún `MarketAlert` para este ticker) — `GET /api/v1/assets/{ticker}` la traduce a un
    502 explícito en vez de devolver un cuerpo vacío o inventado.
    """

    def __init__(self, ticker: str) -> None:
        super().__init__(f"No se pudo generar un análisis para {ticker}.")
        self.ticker = ticker


class AgentRunnerService:
    def __init__(
        self,
        graph_dependencies: GraphDependencies,
        push_service: PushNotificationService,
        session_factory: async_sessionmaker[AsyncSession],
    ) -> None:
        self._graph: CompiledStateGraph[AgentState, None, AgentState, AgentState] = (
            build_graph(graph_dependencies)
        )
        self._push_service = push_service
        self._session_factory = session_factory

    async def run_for_tickers(self, tickers: list[str] | None) -> list[TickerRunResult]:
        resolved_tickers = await self._resolve_tickers(tickers)
        results: list[TickerRunResult] = []
        for ticker, asset_type in resolved_tickers:
            results.append(await self._run_single_ticker(ticker, asset_type))
        return results

    async def _resolve_tickers(
        self, requested: list[str] | None
    ) -> list[tuple[str, AssetType]]:
        async with self._session_factory() as session:
            rows = (
                await session.execute(
                    select(WatchlistItem.ticker, WatchlistItem.asset_type).distinct()
                )
            ).all()

        by_ticker = {ticker: asset_type for ticker, asset_type in rows}
        if requested is None:
            return list(by_ticker.items())

        resolved: list[tuple[str, AssetType]] = []
        for ticker in requested:
            normalized = ticker.upper()
            asset_type = by_ticker.get(normalized)
            if asset_type is None:
                logger.warning(
                    "trigger_agent_ticker_not_in_any_watchlist",
                    extra={"ticker": normalized},
                )
                continue
            resolved.append((normalized, asset_type))
        return resolved

    async def get_or_compute_payload(
        self, ticker: str, asset_type: AssetType, *, max_age: timedelta
    ) -> PushNotificationPayload:
        """Para `GET /api/v1/assets/{ticker}` (Ficha on-demand): devuelve el último
        `PushNotificationPayload` persistido si es lo bastante reciente (`max_age`), o corre
        el motor sincrónicamente para este único ticker si no hay uno fresco. A diferencia de
        `run_for_tickers` (el cron/trigger), NO despacha push a los watchers acá — es una
        lectura activa del usuario que abrió la Ficha, no una alerta nueva; sí se persiste en
        `AlertHistory` para que la próxima lectura on-demand (o el próximo cron) encuentre un
        resultado fresco sin tener que recalcular.
        """

        normalized_ticker = ticker.upper()
        cached = await self._recent_alert_payload(normalized_ticker, max_age=max_age)
        if cached is not None:
            return cached

        payload, _ = await self._invoke_graph(normalized_ticker, asset_type)
        if payload is None:
            raise AssetIntelligenceUnavailableError(normalized_ticker)

        await self._persist_alert_history(payload, push_dispatched=False)
        return payload

    async def _recent_alert_payload(
        self, ticker: str, *, max_age: timedelta
    ) -> PushNotificationPayload | None:
        async with self._session_factory() as session:
            row = await session.scalar(
                select(AlertHistory)
                .where(AlertHistory.ticker == ticker)
                .order_by(AlertHistory.created_at.desc())
                .limit(1)
            )

        if row is None:
            return None

        # Comparación en Python (no en la query SQL): SQLite no guarda offset de timezone
        # para `DateTime(timezone=True)`, así que un WHERE created_at >= cutoff con un
        # datetime tz-aware podría comparar strings con formato distinto. Acá se asume UTC
        # para el valor naive que devuelve `func.now()` en SQLite.
        created_at = row.created_at
        if created_at.tzinfo is None:
            created_at = created_at.replace(tzinfo=timezone.utc)
        if datetime.now(timezone.utc) - created_at > max_age:
            return None

        # strict=False: el payload viaja por la columna JSON de AlertHistory, y JSON no
        # tiene tipo nativo para Decimal/Enum — mismo caso que el resto de las fronteras
        # JSON del proyecto (WatchlistItemCreate, la salida de Gemini en
        # scenario_evaluator.py). Los modelos de dominio siguen siendo strict en general.
        return PushNotificationPayload.model_validate(row.payload_json, strict=False)

    async def _invoke_graph(
        self, ticker: str, asset_type: AssetType
    ) -> tuple[PushNotificationPayload | None, MarketAlert | None]:
        """Corre el grafo y devuelve el payload junto con la `MarketAlert` que lo originó.

        La alerta viaja además del payload porque el payload no lleva la magnitud del disparador
        (ver `src/notification/payload_builder.py`), y es el único dato con el que una regla de
        alerta por precio puede decidir. Sale de acá y no se re-deriva después porque el estado del
        grafo es el único lugar donde existe.
        """

        asset = WatchedAsset(
            ticker=ticker, asset_class=_ASSET_TYPE_TO_ASSET_CLASS[asset_type]
        )
        final_state = await self._graph.ainvoke(
            AgentState(
                watched_asset=asset,
                user_profile=UserProfile.FICHA_INTELIGENCIA_PROFUNDA,
            )
        )
        payload = final_state.get("notification_payload")
        alert = final_state.get("market_alert")
        return (
            payload if isinstance(payload, PushNotificationPayload) else None,
            alert if isinstance(alert, MarketAlert) else None,
        )

    async def _run_single_ticker(
        self, ticker: str, asset_type: AssetType
    ) -> TickerRunResult:
        try:
            payload, market_alert = await self._invoke_graph(ticker, asset_type)
        except Exception as exc:  # noqa: BLE001 — límite de un job por lote: se degrada y
            # se registra explícitamente en vez de propagar, para que un ticker roto (red,
            # proveedor caído, bug) no tumbe la corrida completa del cron sobre el resto de
            # la watchlist (.cursorrules §2: "loggear o degradar explícitamente").
            logger.error(
                "trigger_agent_pipeline_failed",
                extra={"ticker": ticker, "error": str(exc)},
            )
            return TickerRunResult(
                ticker=ticker,
                asset_type=asset_type,
                alert_generated=False,
                error=str(exc),
            )

        if payload is None:
            return TickerRunResult(
                ticker=ticker, asset_type=asset_type, alert_generated=False
            )

        # El Nodo 5 (dentro del grafo) arma el payload pero no lo despacha él mismo en esta
        # corrida in-process: esta app ES el backend propio, así que el despacho real
        # (avisar a los watchers + persistir) lo hace PushNotificationService acá, no un
        # segundo salto HTTP de vuelta hacia sí misma.
        dispatch_result = await self._push_service.dispatch_to_watchers(
            payload, market_alert=market_alert
        )
        push_dispatched = (
            dispatch_result.fcm_dispatched
            or dispatch_result.websocket_delivered_count > 0
            or dispatch_result.device_push_delivered_count > 0
        )
        await self._persist_alert_history(payload, push_dispatched=push_dispatched)

        return TickerRunResult(
            ticker=ticker,
            asset_type=asset_type,
            alert_generated=True,
            urgency_level=payload.urgency_level,
            push_dispatched=push_dispatched,
            watcher_count=dispatch_result.watcher_count,
        )

    async def _persist_alert_history(
        self, payload: PushNotificationPayload, *, push_dispatched: bool
    ) -> None:
        final_payload = payload.model_copy(update={"push_dispatched": push_dispatched})
        async with self._session_factory() as session:
            session.add(
                AlertHistory(
                    ticker=final_payload.ticker,
                    payload_json=final_payload.model_dump(mode="json"),
                    urgency_level=final_payload.urgency_level,
                )
            )
            await session.commit()
