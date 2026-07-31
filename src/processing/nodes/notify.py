"""Nodo 5 — Generador de Salida: alertas push / reportes de dashboard (Spec.md §3.5).

Se llega aquí por tres caminos: (a) severity LOW sin investigación profunda, (b) Guardrail
aprobado (`recommended_action == PASS`), o (c) ruta "abort" del grafo — ya sea por una
contradicción estructural (`recommended_action == ABORT`) o por reintentos agotados (el
Guardrail sigue recomendando `RE_RUN_RESEARCH` pero `route_after_guardrail` fuerza el corte).
En (c) se degrada la salida a solo-datos-crudos, nunca se entrega una interpretación sin
verificar (Spec.md §3.4). Por la topología del grafo, la única forma de llegar a este nodo con
`guardrail_result` presente y distinto de `PASS` es a través de la ruta "abort" — así que
`recommended_action != PASS` identifica correctamente ambos casos de (c), sin necesitar saber
por qué arista se llegó.
"""

from __future__ import annotations

from typing import Any

from src.core.dependencies import GraphDependencies
from src.core.state import AgentState, NodeFn
from src.validation.domain_models import GuardrailAction


def make_notify_node(deps: GraphDependencies) -> NodeFn:
    async def notify_node(state: AgentState) -> dict[str, Any]:
        degraded_raw_data_only = (
            state.guardrail_result is not None
            and state.guardrail_result.recommended_action != GuardrailAction.PASS
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
