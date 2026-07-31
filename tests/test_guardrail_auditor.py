"""Tests del Nodo 4 (`HeuristicGuardrailAuditor`): cada chequeo de integridad por separado
(citas, suma de probabilidades, números fabricados, contradicción narrativa-sentimiento,
sanity de confianza/completitud) y el camino feliz sin hallazgos.
"""

from __future__ import annotations

from datetime import datetime, timezone
from decimal import Decimal
from typing import Literal
from uuid import uuid4

from src.processing.guardrail_auditor import HeuristicGuardrailAuditor
from src.validation.domain_models import (
    AlertSeverity,
    AlertTriggerType,
    AssetClass,
    AssetProjection,
    EvidenceItem,
    GuardrailAction,
    HorizonScenarios,
    MarketAlert,
    ResearchDossier,
    ScenarioOutcome,
)


def _make_alert(trigger_value: Decimal = Decimal("8.72")) -> MarketAlert:
    return MarketAlert(
        alert_id=str(uuid4()),
        ticker="NVDA",
        asset_class=AssetClass.EQUITY,
        trigger_type=AlertTriggerType.PRICE_MOVE,
        severity=AlertSeverity.HIGH,
        detected_at=datetime.now(timezone.utc),
        trigger_value=trigger_value,
        threshold_breached=Decimal("6.0"),
        requires_deep_research=True,
    )


def _make_dossier(evidence: list[EvidenceItem] | None = None) -> ResearchDossier:
    return ResearchDossier(
        ticker="NVDA",
        generated_at=datetime.now(timezone.utc),
        summary="Alerta HIGH detectada. 1 noticia recuperada.",
        evidence=evidence or [],
    )


def _valid_horizon(
    horizon: Literal["CORTO_1_14D", "MEDIANO_1_6M", "LARGO_1_3A"],
    *,
    rationale: str = "Movimiento consistente con el 8.72% reportado en la alerta.",
) -> HorizonScenarios:
    return HorizonScenarios(
        horizon=horizon,
        scenarios=[
            ScenarioOutcome(
                label="ALCISTA", probability_pct=Decimal(50), rationale=rationale
            ),
            ScenarioOutcome(
                label="NEUTRAL", probability_pct=Decimal(30), rationale=rationale
            ),
            ScenarioOutcome(
                label="BAJISTA", probability_pct=Decimal(20), rationale=rationale
            ),
        ],
        confidence_level="MEDIA",
        data_completeness_pct=Decimal(70),
    )


def _make_projection(horizons: list[HorizonScenarios]) -> AssetProjection:
    return AssetProjection(
        ticker="NVDA",
        generated_at=datetime.now(timezone.utc),
        source_alert_id=str(uuid4()),
        horizons=horizons,
        classification="REACCION_EMOCIONAL",
        classification_confidence_pct=Decimal(60),
    )


async def test_clean_projection_passes() -> None:
    auditor = HeuristicGuardrailAuditor()
    dossier = _make_dossier()
    projection = _make_projection(
        [
            _valid_horizon("CORTO_1_14D"),
            _valid_horizon("MEDIANO_1_6M"),
            _valid_horizon("LARGO_1_3A"),
        ]
    )

    result = await auditor.audit(projection, dossier, _make_alert())

    assert result.is_valid is True
    assert result.recommended_action == GuardrailAction.PASS
    assert result.flagged_issues == []
    assert result.hallucination_score == 0.0


async def test_citation_not_in_dossier_recommends_rerun_research() -> None:
    auditor = HeuristicGuardrailAuditor()
    dossier = _make_dossier()
    horizon = HorizonScenarios(
        horizon="CORTO_1_14D",
        scenarios=[
            ScenarioOutcome(
                label="ALCISTA",
                probability_pct=Decimal(50),
                rationale="Momentum positivo.",
                key_evidence_refs=["tavily:no-existe"],
            ),
            ScenarioOutcome(
                label="NEUTRAL", probability_pct=Decimal(30), rationale="Neutral."
            ),
            ScenarioOutcome(
                label="BAJISTA", probability_pct=Decimal(20), rationale="Riesgo bajo."
            ),
        ],
        confidence_level="MEDIA",
        data_completeness_pct=Decimal(70),
    )
    projection = _make_projection([horizon])

    result = await auditor.audit(projection, dossier, _make_alert())

    assert result.is_valid is False
    assert result.recommended_action == GuardrailAction.RE_RUN_RESEARCH
    assert any("no existe en la evidencia" in issue for issue in result.flagged_issues)


async def test_probability_sum_mismatch_recommends_rerun_research() -> None:
    auditor = HeuristicGuardrailAuditor()
    dossier = _make_dossier()
    horizon = HorizonScenarios(
        horizon="CORTO_1_14D",
        scenarios=[
            ScenarioOutcome(
                label="ALCISTA", probability_pct=Decimal(70), rationale="Momentum."
            ),
            ScenarioOutcome(
                label="NEUTRAL", probability_pct=Decimal(30), rationale="Neutral."
            ),
            ScenarioOutcome(
                label="BAJISTA", probability_pct=Decimal(30), rationale="Riesgo."
            ),
        ],
        confidence_level="MEDIA",
        data_completeness_pct=Decimal(70),
    )
    projection = _make_projection([horizon])

    result = await auditor.audit(projection, dossier, _make_alert())

    assert result.is_valid is False
    assert result.recommended_action == GuardrailAction.RE_RUN_RESEARCH
    assert any("suman" in issue for issue in result.flagged_issues)


async def test_fabricated_number_not_in_context_recommends_rerun_research() -> None:
    auditor = HeuristicGuardrailAuditor()
    dossier = _make_dossier()
    horizon = _valid_horizon(
        "CORTO_1_14D",
        rationale="El P/E de 47.3 confirma una valoración exigente que no está en el contexto.",
    )
    projection = _make_projection([horizon])

    result = await auditor.audit(projection, dossier, _make_alert())

    assert result.is_valid is False
    assert result.recommended_action == GuardrailAction.RE_RUN_RESEARCH
    assert any("47.3" in issue for issue in result.flagged_issues)


async def test_grounded_number_from_evidence_does_not_flag() -> None:
    auditor = HeuristicGuardrailAuditor()
    dossier = _make_dossier(
        evidence=[
            EvidenceItem(
                ref_id="tavily:1",
                source_type="NEWS",
                url="https://example.com/n",
                published_at=datetime.now(timezone.utc),
                excerpt="La acción subió 8.72% tras el reporte trimestral de Nvidia.",
            )
        ]
    )
    horizon = _valid_horizon(
        "CORTO_1_14D",
        rationale="El movimiento de 8.72% citado en la nota de prensa respalda el momentum.",
    )
    projection = _make_projection([horizon])

    result = await auditor.audit(
        projection, dossier, _make_alert(trigger_value=Decimal("8.72"))
    )

    assert result.is_valid is True
    assert result.recommended_action == GuardrailAction.PASS


async def test_narrative_contradicts_bullish_label_recommends_abort() -> None:
    auditor = HeuristicGuardrailAuditor()
    dossier = _make_dossier()
    horizon = HorizonScenarios(
        horizon="LARGO_1_3A",
        scenarios=[
            ScenarioOutcome(
                label="ALCISTA",
                probability_pct=Decimal(50),
                rationale="La empresa está al borde de la quiebra pero el precio podría subir igual.",
            ),
            ScenarioOutcome(
                label="NEUTRAL", probability_pct=Decimal(30), rationale="Neutral."
            ),
            ScenarioOutcome(
                label="BAJISTA", probability_pct=Decimal(20), rationale="Riesgo bajo."
            ),
        ],
        confidence_level="MEDIA",
        data_completeness_pct=Decimal(70),
    )
    projection = _make_projection([horizon])

    result = await auditor.audit(projection, dossier, _make_alert())

    assert result.is_valid is False
    assert result.recommended_action == GuardrailAction.ABORT
    assert any("contradice" in issue for issue in result.flagged_issues)


async def test_high_confidence_with_low_completeness_recommends_rerun_research() -> (
    None
):
    auditor = HeuristicGuardrailAuditor()
    dossier = _make_dossier()
    horizon = HorizonScenarios(
        horizon="LARGO_1_3A",
        scenarios=[
            ScenarioOutcome(
                label="ALCISTA", probability_pct=Decimal(50), rationale="Sin cifras."
            ),
            ScenarioOutcome(
                label="NEUTRAL", probability_pct=Decimal(30), rationale="Sin cifras."
            ),
            ScenarioOutcome(
                label="BAJISTA", probability_pct=Decimal(20), rationale="Sin cifras."
            ),
        ],
        confidence_level="ALTA",
        data_completeness_pct=Decimal(20),
    )
    projection = _make_projection([horizon])

    result = await auditor.audit(projection, dossier, _make_alert())

    assert result.is_valid is False
    assert result.recommended_action == GuardrailAction.RE_RUN_RESEARCH
    assert any("completitud" in issue for issue in result.flagged_issues)
