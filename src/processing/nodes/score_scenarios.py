"""Nodo 3 — Evaluador de Escenarios: probabilidades por horizonte (Spec.md §3.3, §4.1).

También es el punto de reintento cuando el Guardrail (Nodo 4) rechaza la proyección: en ese
caso `guardrail_result` llega con verdict=REJECTED y este nodo re-evalúa pasándole ese feedback
al `ScenarioEvaluator` para que acote el contexto a evidencia ya verificada (Spec.md §3.4).
"""

from __future__ import annotations

from typing import Any

from src.core.dependencies import GraphDependencies
from src.core.exceptions import InsufficientMarketDataError
from src.core.state import AgentState, NodeFn
from src.validation.domain_models import GuardrailVerdict


def make_score_scenarios_node(deps: GraphDependencies) -> NodeFn:
    async def score_scenarios_node(state: AgentState) -> dict[str, Any]:
        if state.market_alert is None or state.research_dossier is None:
            raise InsufficientMarketDataError(
                "score_scenarios_node requiere MarketAlert y ResearchDossier ya presentes en el estado."
            )

        is_retry = (
            state.guardrail_result is not None
            and state.guardrail_result.verdict == GuardrailVerdict.REJECTED
        )
        retry_count = (
            state.guardrail_retry_count + 1 if is_retry else state.guardrail_retry_count
        )

        projection = await deps.scenario_evaluator.evaluate(
            asset=state.watched_asset,
            alert=state.market_alert,
            dossier=state.research_dossier,
            guardrail_feedback=state.guardrail_result,
        )

        return {"asset_projection": projection, "guardrail_retry_count": retry_count}

    return score_scenarios_node
