"""Nodo 4 — Guardrail / Auditoría de Alucinaciones (Spec.md §3.4)."""

from __future__ import annotations

from typing import Any

from src.core.dependencies import GraphDependencies
from src.core.exceptions import InsufficientMarketDataError
from src.core.state import AgentState, NodeFn, RouteFn
from src.validation.domain_models import GuardrailAction


def make_guardrail_node(deps: GraphDependencies) -> NodeFn:
    async def guardrail_node(state: AgentState) -> dict[str, Any]:
        if (
            state.asset_projection is None
            or state.research_dossier is None
            or state.market_alert is None
        ):
            raise InsufficientMarketDataError(
                "guardrail_node requiere MarketAlert, AssetProjection y ResearchDossier ya "
                "presentes en el estado."
            )

        result = await deps.guardrail.audit(
            state.asset_projection, state.research_dossier, state.market_alert
        )
        return {"guardrail_result": result}

    return guardrail_node


def make_route_after_guardrail(max_retries: int) -> RouteFn:
    """'retry' vuelve al Nodo 2 (Investigador Profundo) para regenerar el dossier con más
    contexto; 'abort' se usa tanto cuando el Guardrail detecta una contradicción estructural
    (Spec.md §3.4: un error de razonamiento que más investigación no corrige de forma
    confiable) como cuando se agotan los reintentos — en ambos casos el Nodo 5 degrada la
    salida a solo-datos-crudos, nunca entrega una interpretación no verificada.
    """

    def route_after_guardrail(state: AgentState) -> str:
        result = state.guardrail_result
        if result is None:
            return "abort"
        if result.recommended_action == GuardrailAction.PASS:
            return "approved"
        if (
            result.recommended_action == GuardrailAction.RE_RUN_RESEARCH
            and state.guardrail_retry_count < max_retries
        ):
            return "retry"
        return "abort"

    return route_after_guardrail
