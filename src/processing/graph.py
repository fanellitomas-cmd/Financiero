"""Orquestador LangGraph del Copiloto Financiero. Ver Spec.md §3 para la especificación
completa de cada nodo y `.cursorrules` §3 para las reglas de frontera entre capas.

    ingest_and_filter --[deep_research]--> deep_research -> score_scenarios -> guardrail_audit
                      --[notify]---------------------------------------------------> notify
                      --[end_no_alert]----------------------------------------------> END

    guardrail_audit --[approved]--> notify
                    --[retry]-----> score_scenarios   (reintento acotado, hasta max_guardrail_retries)
                    --[abort]-----> notify             (degradado a solo-datos-crudos)

`build_graph` no importa clientes concretos de `ingestion/`/`notification/`: recibe un
`GraphDependencies` ya construido por el llamador (composition root), manteniendo `processing/`
testeable con dobles de prueba y desacoplado de la implementación de cada proveedor.
"""

from __future__ import annotations

from langgraph.graph import END, StateGraph
from langgraph.graph.state import CompiledStateGraph

from src.core.config import Settings
from src.core.config import settings as default_settings
from src.core.dependencies import GraphDependencies
from src.core.state import AgentState
from src.processing.nodes.deep_research import make_deep_research_node
from src.processing.nodes.guardrail import (
    make_guardrail_node,
    make_route_after_guardrail,
)
from src.processing.nodes.ingest_and_filter import (
    make_ingest_and_filter_node,
    route_after_ingestion,
)
from src.processing.nodes.notify import make_notify_node
from src.processing.nodes.score_scenarios import make_score_scenarios_node

INGEST_AND_FILTER = "ingest_and_filter"
DEEP_RESEARCH = "deep_research"
SCORE_SCENARIOS = "score_scenarios"
GUARDRAIL_AUDIT = "guardrail_audit"
NOTIFY = "notify"


def build_graph(
    deps: GraphDependencies,
    settings: Settings = default_settings,
) -> CompiledStateGraph[AgentState, None, AgentState, AgentState]:
    graph = StateGraph(AgentState)

    graph.add_node(INGEST_AND_FILTER, make_ingest_and_filter_node(deps))
    graph.add_node(DEEP_RESEARCH, make_deep_research_node(deps))
    graph.add_node(SCORE_SCENARIOS, make_score_scenarios_node(deps))
    graph.add_node(GUARDRAIL_AUDIT, make_guardrail_node(deps))
    graph.add_node(NOTIFY, make_notify_node(deps))

    graph.set_entry_point(INGEST_AND_FILTER)

    graph.add_conditional_edges(
        INGEST_AND_FILTER,
        route_after_ingestion,
        {
            "deep_research": DEEP_RESEARCH,
            "notify": NOTIFY,
            "end_no_alert": END,
        },
    )

    graph.add_edge(DEEP_RESEARCH, SCORE_SCENARIOS)
    graph.add_edge(SCORE_SCENARIOS, GUARDRAIL_AUDIT)

    graph.add_conditional_edges(
        GUARDRAIL_AUDIT,
        make_route_after_guardrail(settings.max_guardrail_retries),
        {
            "approved": NOTIFY,
            "retry": SCORE_SCENARIOS,
            "abort": NOTIFY,
        },
    )

    graph.add_edge(NOTIFY, END)

    return graph.compile()
