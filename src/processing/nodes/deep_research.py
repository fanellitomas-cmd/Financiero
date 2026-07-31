"""Nodo 2 — Investigador Profundo: RAG sobre noticias, filings SEC y transcripciones (Spec.md §3.2)."""

from __future__ import annotations

from typing import Any

from src.core.dependencies import GraphDependencies
from src.core.exceptions import InsufficientMarketDataError
from src.core.state import AgentState, NodeFn


def make_deep_research_node(deps: GraphDependencies) -> NodeFn:
    async def deep_research_node(state: AgentState) -> dict[str, Any]:
        if state.market_alert is None:
            raise InsufficientMarketDataError(
                "deep_research_node invocado sin MarketAlert; revisar routing del Nodo 1."
            )

        dossier = await deps.deep_research.build_dossier(
            state.watched_asset, state.market_alert
        )
        return {"research_dossier": dossier}

    return deep_research_node
