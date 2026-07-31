"""Nodo 1 — Ingesta & Monitoreo en Tiempo Real (Spec.md §3.1)."""

from __future__ import annotations

from typing import Any

from src.core.dependencies import GraphDependencies
from src.core.exceptions import ProviderRateLimitError, StaleDataError
from src.core.state import AgentState, NodeFn


def make_ingest_and_filter_node(deps: GraphDependencies) -> NodeFn:
    async def ingest_and_filter_node(state: AgentState) -> dict[str, Any]:
        try:
            alert = await deps.market_data.fetch_snapshot_and_detect_alert(
                state.watched_asset
            )
        except ProviderRateLimitError as exc:
            return {
                "error_log": [*state.error_log, f"provider_rate_limit: {exc}"],
                "market_alert": None,
            }
        except StaleDataError as exc:
            return {
                "error_log": [*state.error_log, f"stale_data: {exc}"],
                "market_alert": None,
            }

        return {"market_alert": alert}

    return ingest_and_filter_node


def route_after_ingestion(state: AgentState) -> str:
    """LOW severity o sin alerta evitan el costo de investigación profunda (Spec.md §3.1)."""

    if state.market_alert is None:
        return "end_no_alert"
    if state.market_alert.requires_deep_research:
        return "deep_research"
    return "notify"
