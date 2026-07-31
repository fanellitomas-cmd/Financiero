"""Orquesta la ejecución del pipeline de LangGraph (`src/`) sobre los tickers activos en
`Watchlists`, invocado por el Cron/Scheduler externo vía `POST /internal/trigger-agent`.

Corre el grafo UNA vez por ticker (no una vez por usuario): el `PushNotificationPayload` que
produce el Nodo 5 ya incluye ambas narrativas (técnica y principiante, ver
`src/notification/payload_builder.py`), así que la preferencia `enable_beginner_mode` de cada
usuario se resuelve del lado del cliente/push, no re-corriendo el análisis por usuario.
"""

from __future__ import annotations

import logging

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
    PushNotificationPayload,
    UserProfile,
    WatchedAsset,
)

logger = logging.getLogger(__name__)

_ASSET_TYPE_TO_ASSET_CLASS = {
    AssetType.STOCK: AssetClass.EQUITY,
    AssetType.CRYPTO: AssetClass.CRYPTO,
}


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

    async def _run_single_ticker(
        self, ticker: str, asset_type: AssetType
    ) -> TickerRunResult:
        asset = WatchedAsset(
            ticker=ticker, asset_class=_ASSET_TYPE_TO_ASSET_CLASS[asset_type]
        )

        try:
            final_state = await self._graph.ainvoke(
                AgentState(
                    watched_asset=asset,
                    user_profile=UserProfile.FICHA_INTELIGENCIA_PROFUNDA,
                )
            )
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

        payload = final_state.get("notification_payload")
        if payload is None:
            return TickerRunResult(
                ticker=ticker, asset_type=asset_type, alert_generated=False
            )

        # El Nodo 5 (dentro del grafo) arma el payload pero no lo despacha él mismo en esta
        # corrida in-process: esta app ES el backend propio, así que el despacho real
        # (avisar a los watchers + persistir) lo hace PushNotificationService acá, no un
        # segundo salto HTTP de vuelta hacia sí misma.
        dispatch_result = await self._push_service.dispatch_to_watchers(payload)
        push_dispatched = (
            dispatch_result.fcm_dispatched
            or dispatch_result.websocket_delivered_count > 0
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
