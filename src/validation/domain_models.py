"""Modelos Pydantic de dominio compartidos por el grafo. Ver Spec.md §2 para el contrato completo.

Esta capa no realiza I/O de red (Spec.md / .cursorrules §3): solo define y valida forma de datos.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from enum import Enum
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class AssetClass(str, Enum):
    EQUITY = "EQUITY"
    CRYPTO = "CRYPTO"


class UserProfile(str, Enum):
    TRADUCTOR_FINANCIERO = "TRADUCTOR_FINANCIERO"
    FICHA_INTELIGENCIA_PROFUNDA = "FICHA_INTELIGENCIA_PROFUNDA"


class DataStatus(str, Enum):
    OK = "OK"
    NO_DISPONIBLE = "NO_DISPONIBLE"
    ERROR_API = "ERROR_API"
    STALE = "STALE"


class MetricValue(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    value: Decimal | None
    status: DataStatus
    source: str
    as_of: datetime | None = None


class WatchedAsset(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ticker: str
    asset_class: AssetClass


class AlertSeverity(str, Enum):
    LOW = "LOW"
    MEDIUM = "MEDIUM"
    HIGH = "HIGH"
    CRITICAL = "CRITICAL"


class AlertTriggerType(str, Enum):
    PRICE_MOVE = "PRICE_MOVE"
    VOLUME_SPIKE = "VOLUME_SPIKE"
    NEWS_SHOCK = "NEWS_SHOCK"
    ON_CHAIN_ANOMALY = "ON_CHAIN_ANOMALY"
    VOLATILITY_SPIKE = "VOLATILITY_SPIKE"
    FUNDAMENTAL_CHANGE = "FUNDAMENTAL_CHANGE"


class MarketAlert(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    alert_id: str
    ticker: str
    asset_class: AssetClass
    trigger_type: AlertTriggerType
    severity: AlertSeverity
    detected_at: datetime

    trigger_value: Decimal | None
    threshold_breached: Decimal | None

    requires_deep_research: bool
    raw_context_snapshot: dict[str, str] = Field(default_factory=dict)


class EvidenceItem(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ref_id: str
    source_type: Literal[
        "NEWS",
        "SEC_10K",
        "SEC_10Q",
        "EARNINGS_TRANSCRIPT",
        "ON_CHAIN_DASHBOARD",
        "OFFICIAL_ANNOUNCEMENT",
    ]
    url: str | None
    published_at: datetime | None
    excerpt: str


class ResearchDossier(BaseModel):
    """Salida del Nodo 2. Contexto enriquecido, no expuesto directamente al usuario (Spec.md §3.2)."""

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ticker: str
    generated_at: datetime
    summary: str
    evidence: list[EvidenceItem] = Field(default_factory=list)
    fundamental_deterioration_score: Decimal | None = None
    market_reaction_magnitude: Decimal | None = None


class ScenarioOutcome(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    label: Literal["ALCISTA", "NEUTRAL", "BAJISTA"]
    probability_pct: Decimal = Field(ge=0, le=100)
    rationale: str
    key_evidence_refs: list[str] = Field(default_factory=list)


class HorizonScenarios(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    horizon: Literal["CORTO_1_14D", "MEDIANO_1_6M", "LARGO_1_3A"]
    scenarios: list[ScenarioOutcome]
    confidence_level: Literal["BAJA", "MEDIA", "ALTA"]
    data_completeness_pct: Decimal = Field(ge=0, le=100)


class AssetProjection(BaseModel):
    """Salida del Nodo 3. Ver Spec.md §2.5 y §4.1 para la metodología de clasificación."""

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ticker: str
    generated_at: datetime
    source_alert_id: str

    horizons: list[HorizonScenarios]
    classification: Literal[
        "REACCION_EMOCIONAL", "DETERIORO_FUNDAMENTAL", "INDETERMINADO"
    ]
    classification_confidence_pct: Decimal = Field(ge=0, le=100)


class GuardrailVerdict(str, Enum):
    APPROVED = "APPROVED"
    REJECTED = "REJECTED"


class GuardrailFinding(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    check_name: Literal[
        "GROUNDING_CHECK",
        "NUMERIC_CONSISTENCY",
        "SOURCE_WHITELIST",
        "RECENCY_CHECK",
        "MAGNITUDE_SANITY",
    ]
    passed: bool
    detail: str


class GuardrailResult(BaseModel):
    """Salida del Nodo 4. Ver Spec.md §3.4 para el detalle de cada check."""

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    verdict: GuardrailVerdict
    findings: list[GuardrailFinding]
    evaluated_at: datetime


class NotificationPayload(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ticker: str
    user_profile: UserProfile
    degraded_raw_data_only: bool = False
    rendered_text: str
    asset_projection: AssetProjection | None = None
