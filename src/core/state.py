"""Estado compartido del grafo LangGraph. Pydantic v2 strict por .cursorrules §1/§2:
ningún campo asume un valor por defecto que pueda confundirse con un dato real.
"""

from __future__ import annotations

from collections.abc import Awaitable
from typing import Any, Protocol

from pydantic import BaseModel, ConfigDict, Field

from src.validation.domain_models import (
    AssetProjection,
    GuardrailResult,
    MarketAlert,
    NotificationPayload,
    ResearchDossier,
    UserProfile,
    WatchedAsset,
)


class AgentState(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    watched_asset: WatchedAsset
    user_profile: UserProfile

    market_alert: MarketAlert | None = None
    research_dossier: ResearchDossier | None = None
    asset_projection: AssetProjection | None = None
    guardrail_result: GuardrailResult | None = None
    notification_payload: NotificationPayload | None = None

    guardrail_retry_count: int = 0
    error_log: list[str] = Field(default_factory=list)


class NodeFn(Protocol):
    def __call__(self, state: AgentState) -> Awaitable[dict[str, Any]]: ...


class RouteFn(Protocol):
    def __call__(self, state: AgentState) -> str: ...
