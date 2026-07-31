"""Nodo 5 — Generador de Salida: alertas push / reportes de dashboard (Spec.md §3.5).

Se llega aquí por tres caminos: (a) severity LOW sin investigación profunda, (b) Guardrail
aprobado, o (c) reintentos de Guardrail agotados — en (c) se fuerza `degraded_raw_data_only`
para no entregar una interpretación sin verificar (Spec.md §3.4).
"""

from __future__ import annotations

from typing import Any

from src.core.dependencies import GraphDependencies
from src.core.state import AgentState, NodeFn
from src.validation.domain_models import GuardrailVerdict


def make_notify_node(deps: GraphDependencies) -> NodeFn:
    async def notify_node(state: AgentState) -> dict[str, Any]:
        degraded_raw_data_only = (
            state.guardrail_result is not None
            and state.guardrail_result.verdict == GuardrailVerdict.REJECTED
        )

        payload = await deps.notifier.render_and_send(
            asset=state.watched_asset,
            user_profile=state.user_profile,
            alert=state.market_alert,
            projection=None if degraded_raw_data_only else state.asset_projection,
            degraded_raw_data_only=degraded_raw_data_only,
        )
        return {"notification_payload": payload}

    return notify_node
