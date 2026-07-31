"""Composition root: ensambla instancias concretas de ingesta detrás de los puertos que
`processing/` consume (`core/dependencies.py`). Solo este módulo conoce simultáneamente los
clientes HTTP de `ingestion/` y las Protocols de `processing/` — ningún nodo importa
`PolygonClient`/`FMPClient`/`TavilyClient` directamente (.cursorrules §3).
"""

from __future__ import annotations

from dataclasses import dataclass

from src.core.dependencies import (
    DeepResearchProvider,
    GuardrailAuditor,
    MarketDataProvider,
    NotificationDispatcher,
    ScenarioEvaluator,
)
from src.ingestion.adapters import (
    FundamentalsAndNewsResearchAdapter,
    PolygonMarketDataAdapter,
)
from src.ingestion.fmp_client import FMPClient
from src.ingestion.gemini_client import GeminiClient
from src.ingestion.polygon_client import PolygonClient
from src.ingestion.tavily_client import TavilyClient
from src.processing.scenario_evaluator import GeminiScenarioEvaluator


@dataclass
class RuntimeGraphDependencies:
    """Implementación concreta de `GraphDependencies` (Protocol, `core/dependencies.py`):
    satisface su forma estructuralmente sin heredar de él, para poder pasarse tal cual a
    `processing.graph.build_graph`.
    """

    market_data: MarketDataProvider
    deep_research: DeepResearchProvider
    scenario_evaluator: ScenarioEvaluator
    guardrail: GuardrailAuditor
    notifier: NotificationDispatcher


def build_ingestion_backed_dependencies(
    polygon_client: PolygonClient,
    fmp_client: FMPClient,
    tavily_client: TavilyClient,
    *,
    gemini_client: GeminiClient | None = None,
    scenario_evaluator: ScenarioEvaluator | None = None,
    guardrail: GuardrailAuditor,
    notifier: NotificationDispatcher,
) -> RuntimeGraphDependencies:
    """Conecta los clientes HTTP ya inicializados a los puertos `market_data` (Nodo 1),
    `deep_research` (Nodo 2) y `scenario_evaluator` (Nodo 3, Gemini).

    `scenario_evaluator` puede pasarse explícito (ej. un doble de prueba) o construirse
    automáticamente a partir de `gemini_client`; se requiere exactamente uno de los dos. Los
    puertos de los Nodos 4/5 todavía no tienen implementación de producción — el llamador
    debe proveerlos explícitamente; esta función nunca los rellena con un stub silencioso.
    """

    if scenario_evaluator is None:
        if gemini_client is None:
            raise ValueError(
                "build_ingestion_backed_dependencies requiere scenario_evaluator o "
                "gemini_client (para construir GeminiScenarioEvaluator automáticamente)."
            )
        scenario_evaluator = GeminiScenarioEvaluator(gemini_client)

    return RuntimeGraphDependencies(
        market_data=PolygonMarketDataAdapter(polygon_client),
        deep_research=FundamentalsAndNewsResearchAdapter(tavily_client, fmp_client),
        scenario_evaluator=scenario_evaluator,
        guardrail=guardrail,
        notifier=notifier,
    )
