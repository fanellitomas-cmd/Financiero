"""Nodo 4 — Guardrail / Auditoría de Alucinaciones (Spec.md §3.4)."""

from __future__ import annotations

from typing import Any

from src.core.dependencies import GraphDependencies
from src.core.exceptions import InsufficientMarketDataError
from src.core.state import AgentState, NodeFn, RouteFn
from src.validation.domain_models import GuardrailVerdict


def make_guardrail_node(deps: GraphDependencies) -> NodeFn:
    async def guardrail_node(state: AgentState) -> dict[str, Any]:
        if state.asset_projection is None or state.research_dossier is None:
            raise InsufficientMarketDataError(
                "guardrail_node requiere AssetProjection y ResearchDossier ya presentes en el estado."
            )

        result = await deps.guardrail.audit(
            state.asset_projection, state.research_dossier
        )
        return {"guardrail_result": result}

    return guardrail_node


def make_route_after_guardrail(max_retries: int) -> RouteFn:
    """'retry' vuelve al Nodo 3 con contexto acotado; 'abort' agota reintentos y degrada la
    salida a solo-datos-crudos en el Nodo 5, nunca entrega una interpretación no verificada
    (Spec.md §3.4).
    """

    def route_after_guardrail(state: AgentState) -> str:
        if state.guardrail_result is None:
            return "abort"
        if state.guardrail_result.verdict == GuardrailVerdict.APPROVED:
            return "approved"
        if state.guardrail_retry_count < max_retries:
            return "retry"
        return "abort"

    return route_after_guardrail
