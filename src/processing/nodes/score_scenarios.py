"""Nodo 3 — Evaluador de Escenarios: probabilidades por horizonte (Spec.md §3.3, §4.1).

Cuando llega aquí tras un reintento (el Guardrail recomendó `RE_RUN_RESEARCH` y el Nodo 2 ya
regeneró el dossier), recibe `state.guardrail_result` como `guardrail_feedback` para que el
`ScenarioEvaluator` acote su razonamiento a evidencia ya verificada (Spec.md §3.4). El conteo
de reintentos vive en el Nodo 2 (punto real de reentrada del ciclo), no aquí.
"""

from __future__ import annotations

from typing import Any

from src.core.dependencies import GraphDependencies
from src.core.exceptions import InsufficientMarketDataError
from src.core.state import AgentState, NodeFn


def make_score_scenarios_node(deps: GraphDependencies) -> NodeFn:
    async def score_scenarios_node(state: AgentState) -> dict[str, Any]:
        if state.market_alert is None or state.research_dossier is None:
            raise InsufficientMarketDataError(
                "score_scenarios_node requiere MarketAlert y ResearchDossier ya presentes en el estado."
            )

        projection = await deps.scenario_evaluator.evaluate(
            asset=state.watched_asset,
            alert=state.market_alert,
            dossier=state.research_dossier,
            guardrail_feedback=state.guardrail_result,
        )

        return {"asset_projection": projection}

    return score_scenarios_node
