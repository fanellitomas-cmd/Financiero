"""Nodo 2 — Investigador Profundo: RAG sobre noticias, filings SEC y transcripciones (Spec.md §3.2).

También es el punto de reentrada cuando el Guardrail (Nodo 4) recomienda `RE_RUN_RESEARCH`:
en ese caso se regenera el dossier (más contexto puede resolver una cita faltante o una cifra
no verificable) y se incrementa el contador de reintentos que acota el ciclo Nodo 2→3→4
(Spec.md §3.4).
"""

from __future__ import annotations

from typing import Any

from src.core.dependencies import GraphDependencies
from src.core.exceptions import InsufficientMarketDataError
from src.core.state import AgentState, NodeFn
from src.validation.domain_models import GuardrailAction


def make_deep_research_node(deps: GraphDependencies) -> NodeFn:
    async def deep_research_node(state: AgentState) -> dict[str, Any]:
        if state.market_alert is None:
            raise InsufficientMarketDataError(
                "deep_research_node invocado sin MarketAlert; revisar routing del Nodo 1."
            )

        is_retry = (
            state.guardrail_result is not None
            and state.guardrail_result.recommended_action
            == GuardrailAction.RE_RUN_RESEARCH
        )
        retry_count = (
            state.guardrail_retry_count + 1 if is_retry else state.guardrail_retry_count
        )

        dossier = await deps.deep_research.build_dossier(
            state.watched_asset, state.market_alert
        )
        return {"research_dossier": dossier, "guardrail_retry_count": retry_count}

    return deep_research_node
