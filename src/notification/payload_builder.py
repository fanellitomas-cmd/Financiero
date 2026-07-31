"""Construye el `PushNotificationPayload` (Nodo 5, Spec.md §3.5 y §4.2) — ya no un texto de
chat para un tercero, sino un JSON estructurado para push nativo + consumo de la API del
frontend. Genera SIEMPRE ambas narrativas (técnica y principiante): el toggle "Explicar para
Principiantes" pasa a ser una decisión del cliente/app (qué narrativa mostrar por defecto vía
`default_view`), no algo que el backend decida de forma irreversible al momento del push
(Spec.md §4.2).
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Literal
from uuid import uuid4

from src.validation.domain_models import (
    AlertSeverity,
    AnalysisNarrative,
    AssetClass,
    AssetProjection,
    MarketAlert,
    PushNotificationPayload,
    UserProfile,
    WatchedAsset,
)

_SEVERITY_EMOJI = {
    AlertSeverity.LOW: "🟢",
    AlertSeverity.MEDIUM: "🟡",
    AlertSeverity.HIGH: "🟠",
    AlertSeverity.CRITICAL: "🔴",
}

_HORIZON_LABELS = {
    "CORTO_1_14D": "Corto Plazo (1-14 días)",
    "MEDIANO_1_6M": "Mediano Plazo (1-6 meses)",
    "LARGO_1_3A": "Largo Plazo (1-3 años)",
}

_CLASSIFICATION_LABELS_ADVANCED = {
    "REACCION_EMOCIONAL": "Reacción Emocional del Mercado",
    "DETERIORO_FUNDAMENTAL": "Deterioro Fundamental",
    "INDETERMINADO": "Indeterminado",
}

_CLASSIFICATION_LABELS_BEGINNER = {
    "REACCION_EMOCIONAL": "Esto parece más nerviosismo del mercado que un problema real de la empresa/proyecto.",
    "DETERIORO_FUNDAMENTAL": "Esto refleja un cambio real en cómo le está yendo a la empresa/proyecto, no solo humor del mercado.",
    "INDETERMINADO": "Todavía no hay suficiente información confiable para saber si esto es ruido o algo serio.",
}

_CONFIDENCE_SEMAPHORE = {"ALTA": "🟢", "MEDIA": "🟡", "BAJA": "🟠"}

_BEGINNER_SCENARIO_PHRASES = {
    "ALCISTA": "Podría subir en este horizonte.",
    "NEUTRAL": "Podría mantenerse relativamente estable en este horizonte.",
    "BAJISTA": "Podría bajar en este horizonte.",
}


def _asset_type(asset: WatchedAsset) -> Literal["stock", "crypto"]:
    return "crypto" if asset.asset_class == AssetClass.CRYPTO else "stock"


def _default_view(user_profile: UserProfile) -> Literal["technical", "beginner"]:
    return (
        "beginner" if user_profile == UserProfile.TRADUCTOR_FINANCIERO else "technical"
    )


def _build_technical_narrative(projection: AssetProjection) -> AnalysisNarrative:
    headline = (
        f"{_CLASSIFICATION_LABELS_ADVANCED[projection.classification]} "
        f"({projection.classification_confidence_pct}% confianza)"
    )
    explanations = []
    for horizon in projection.horizons:
        scenario_line = ", ".join(
            f"{scenario.label} {scenario.probability_pct}%"
            for scenario in horizon.scenarios
        )
        explanations.append(
            f"{_HORIZON_LABELS[horizon.horizon]}: {scenario_line} "
            f"(confianza {horizon.confidence_level}, completitud {horizon.data_completeness_pct}%)"
        )
    return AnalysisNarrative(headline=headline, horizon_explanations=explanations)


def _build_beginner_narrative(projection: AssetProjection) -> AnalysisNarrative:
    headline = _CLASSIFICATION_LABELS_BEGINNER[projection.classification]
    explanations = []
    for horizon in projection.horizons:
        dominant = max(horizon.scenarios, key=lambda scenario: scenario.probability_pct)
        semaphore = _CONFIDENCE_SEMAPHORE[horizon.confidence_level]
        phrase = f"{semaphore} {_HORIZON_LABELS[horizon.horizon]}: {_BEGINNER_SCENARIO_PHRASES[dominant.label]}"
        if horizon.confidence_level == "BAJA":
            phrase += " Con la información disponible hasta ahora, todavía no hay certeza suficiente."
        explanations.append(phrase)
    return AnalysisNarrative(headline=headline, horizon_explanations=explanations)


def build_push_payload(
    *,
    asset: WatchedAsset,
    user_profile: UserProfile,
    alert: MarketAlert | None,
    projection: AssetProjection | None,
    degraded_raw_data_only: bool,
    action_url_template: str,
) -> PushNotificationPayload:
    """Arma el payload pre-despacho (`push_dispatched=False`, `alert_db_id=None`); el
    dispatcher lo completa con `.model_copy(update=...)` después de intentar el envío real.
    """

    urgency = alert.severity if alert is not None else AlertSeverity.LOW
    emoji = _SEVERITY_EMOJI[urgency]
    action_url = action_url_template.format(ticker=asset.ticker)
    timestamp = datetime.now(timezone.utc)

    if degraded_raw_data_only:
        title = f"{emoji} {asset.ticker}: revisión pendiente"
        short_summary = (
            "Detectamos un movimiento importante, pero todavía no pudimos confirmarlo con "
            "suficiente confianza."
        )
        narrative_body = (
            "El Guardrail marcó la interpretación generada como no verificable contra el "
            "contexto disponible (o se agotaron los reintentos permitidos). Se retiene la "
            "interpretación hasta poder confirmarla."
        )
        technical_narrative = AnalysisNarrative(headline=narrative_body)
        beginner_narrative = AnalysisNarrative(headline=short_summary)
        full_analysis: AssetProjection | None = None
    elif projection is None:
        title = f"{emoji} {asset.ticker}: variación menor"
        short_summary = (
            "Cambio menor detectado; no parece requerir tu atención por ahora."
        )
        narrative_body = "Variación dentro de los umbrales configurados; no se activó investigación profunda."
        technical_narrative = AnalysisNarrative(headline=narrative_body)
        beginner_narrative = AnalysisNarrative(headline=short_summary)
        full_analysis = None
    else:
        title = f"{emoji} {asset.ticker}: {_CLASSIFICATION_LABELS_ADVANCED[projection.classification]}"
        short_summary = _CLASSIFICATION_LABELS_BEGINNER[projection.classification]
        technical_narrative = _build_technical_narrative(projection)
        beginner_narrative = _build_beginner_narrative(projection)
        full_analysis = projection

    return PushNotificationPayload(
        notification_id=str(uuid4()),
        ticker=asset.ticker,
        asset_type=_asset_type(asset),
        title=title,
        short_summary=short_summary,
        full_analysis_json=full_analysis,
        technical_narrative=technical_narrative,
        beginner_narrative=beginner_narrative,
        default_view=_default_view(user_profile),
        urgency_level=urgency,
        action_url=action_url,
        timestamp=timestamp,
        degraded_raw_data_only=degraded_raw_data_only,
        push_dispatched=False,
        alert_db_id=None,
    )
