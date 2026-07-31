"""Puertos (Protocols) que los nodos de `processing/` invocan. Las implementaciones concretas
viven en `ingestion/` y `notification/` (Spec.md §3, .cursorrules §3) y se inyectan una única
vez al construir el grafo — los nodos nunca instancian un cliente HTTP directamente.
"""

from __future__ import annotations

from typing import Protocol

from src.validation.domain_models import (
    AssetProjection,
    GuardrailResult,
    MarketAlert,
    NotificationPayload,
    ResearchDossier,
    UserProfile,
    WatchedAsset,
)


class MarketDataProvider(Protocol):
    """Nodo 1: snapshot de mercado + evaluación de umbrales (Spec.md §3.1)."""

    async def fetch_snapshot_and_detect_alert(
        self, asset: WatchedAsset
    ) -> MarketAlert | None: ...


class DeepResearchProvider(Protocol):
    """Nodo 2: RAG sobre noticias, filings y transcripciones (Spec.md §3.2)."""

    async def build_dossier(
        self, asset: WatchedAsset, alert: MarketAlert
    ) -> ResearchDossier: ...


class ScenarioEvaluator(Protocol):
    """Nodo 3: distribución de probabilidades por horizonte (Spec.md §3.3)."""

    async def evaluate(
        self,
        asset: WatchedAsset,
        alert: MarketAlert,
        dossier: ResearchDossier,
        guardrail_feedback: GuardrailResult | None,
    ) -> AssetProjection: ...


class GuardrailAuditor(Protocol):
    """Nodo 4: auditoría de alucinaciones (Spec.md §3.4)."""

    async def audit(
        self, projection: AssetProjection, dossier: ResearchDossier
    ) -> GuardrailResult: ...


class NotificationDispatcher(Protocol):
    """Nodo 5: formateo por perfil + envío a Telegram/Discord (Spec.md §3.5)."""

    async def render_and_send(
        self,
        asset: WatchedAsset,
        user_profile: UserProfile,
        alert: MarketAlert | None,
        projection: AssetProjection | None,
        degraded_raw_data_only: bool,
    ) -> NotificationPayload: ...


class GraphDependencies(Protocol):
    market_data: MarketDataProvider
    deep_research: DeepResearchProvider
    scenario_evaluator: ScenarioEvaluator
    guardrail: GuardrailAuditor
    notifier: NotificationDispatcher
