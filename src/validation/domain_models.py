"""Modelos Pydantic de dominio compartidos por el grafo. Ver Spec.md §2 para el contrato completo.

Esta capa no realiza I/O de red (Spec.md / .cursorrules §3): solo define y valida forma de datos.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from enum import Enum
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


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


class FinancialMetrics(BaseModel):
    """Fundamentales de una acción en un instante dado (Spec.md §2.2). Inmutable: snapshot."""

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ticker: str
    fetched_at: datetime

    price_earnings_ratio: MetricValue
    price_earnings_growth_ratio: MetricValue
    debt_to_ebitda: MetricValue
    # Apalancamiento contra patrimonio, complementario a `debt_to_ebitda` (que lo mide contra
    # generación de caja): una empresa puede tener poca deuda sobre EBITDA y estar muy
    # apalancada sobre equity, o al revés. La Ficha de Inteligencia Profunda muestra los dos.
    debt_to_equity: MetricValue
    free_cash_flow: MetricValue
    free_cash_flow_yield_pct: MetricValue
    revenue_growth_yoy_pct: MetricValue
    gross_margin_pct: MetricValue
    operating_margin_pct: MetricValue
    return_on_equity_pct: MetricValue
    current_ratio: MetricValue
    shares_outstanding: MetricValue
    market_cap: MetricValue

    fundamentals_period: Literal["TTM", "FY", "Q"] = "TTM"
    fundamentals_report_date: datetime | None = None


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
    financial_metrics: FinancialMetrics | None = None
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


class GuardrailAction(str, Enum):
    PASS = "PASS"
    RE_RUN_RESEARCH = "RE-RUN_RESEARCH"
    ABORT = "ABORT"


class GuardrailResult(BaseModel):
    """Salida del Nodo 4 (Spec.md §3.4): auditoría de alucinaciones sobre un `AssetProjection`
    antes de que llegue al Nodo 5. `is_valid`/`flagged_issues`/`recommended_action` deben ser
    mutuamente consistentes — se valida al construir el objeto, nunca se confía en que el
    llamador los arme bien a mano.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    is_valid: bool
    hallucination_score: float = Field(ge=0.0, le=1.0)
    flagged_issues: list[str] = Field(default_factory=list)
    recommended_action: GuardrailAction
    evaluated_at: datetime

    @model_validator(mode="after")
    def _check_internal_consistency(self) -> GuardrailResult:
        if self.is_valid and self.flagged_issues:
            raise ValueError(
                "GuardrailResult inconsistente: is_valid=True con flagged_issues no vacío."
            )
        if self.is_valid != (self.recommended_action == GuardrailAction.PASS):
            raise ValueError(
                "GuardrailResult inconsistente: is_valid debe coincidir con "
                "recommended_action == PASS."
            )
        return self


class AnalysisNarrative(BaseModel):
    """Una de las dos versiones (técnica o principiante) del análisis narrativo, para que la
    app decida cuál mostrar según la preferencia del usuario sin necesitar un nuevo push
    (Spec.md §4.2: el toggle "Explicar para Principiantes" es una decisión del cliente).
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    headline: str
    horizon_explanations: list[str] = Field(default_factory=list)


class PushNotificationPayload(BaseModel):
    """Salida del Nodo 5 (Spec.md §3.5): payload JSON estructurado para notificación push
    nativa + registro en el backend propio — ya no un texto de chat para un tercero. Incluye
    ambas narrativas (técnica y accesible) siempre, y el estado real de entrega
    (`push_dispatched`, `alert_db_id`) se completa después de despachar.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    notification_id: str
    ticker: str
    asset_type: Literal["stock", "crypto"]
    title: str
    short_summary: str
    full_analysis_json: AssetProjection | None = None
    technical_narrative: AnalysisNarrative
    beginner_narrative: AnalysisNarrative
    default_view: Literal["technical", "beginner"]
    urgency_level: AlertSeverity
    action_url: str
    timestamp: datetime

    degraded_raw_data_only: bool = False
    push_dispatched: bool
    alert_db_id: str | None = None
