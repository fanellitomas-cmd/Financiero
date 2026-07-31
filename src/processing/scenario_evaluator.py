"""Nodo 3 — Evaluador de Escenarios (Spec.md §3.3, §4.1). Implementa `ScenarioEvaluator`
(`core/dependencies.py`) invocando Gemini con salida forzada a JSON estructurado, validada
contra los modelos de dominio antes de devolverla. El system prompt completo que gobierna el
razonamiento vive en `prompts/analyst_system_prompt.md` — este módulo arma el contrato de
contexto (su §3), llama al LLM, y nunca deja pasar un número que el LLM no haya fundamentado.

El LLM solo produce los campos de juicio analítico (`horizons`, `classification`,
`classification_confidence_pct`); `ticker`, `generated_at` y `source_alert_id` los fija el
código con datos ya conocidos — así un error del LLM nunca puede corromper el ticker o el id
de la alerta que estamos evaluando.
"""

from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from src.ingestion.gemini_client import GeminiClient
from src.validation.domain_models import (
    AssetProjection,
    DataStatus,
    GuardrailResult,
    HorizonScenarios,
    MarketAlert,
    ResearchDossier,
    ScenarioOutcome,
    WatchedAsset,
)

logger = logging.getLogger(__name__)

_PROMPT_PATH = (
    Path(__file__).resolve().parents[2] / "prompts" / "analyst_system_prompt.md"
)
_PROBABILITY_SUM_TOLERANCE = Decimal("0.5")
_HorizonLabel = Literal["CORTO_1_14D", "MEDIANO_1_6M", "LARGO_1_3A"]
_HORIZONS: tuple[_HorizonLabel, ...] = ("CORTO_1_14D", "MEDIANO_1_6M", "LARGO_1_3A")

_RESPONSE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "horizons": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "horizon": {
                        "type": "string",
                        "enum": ["CORTO_1_14D", "MEDIANO_1_6M", "LARGO_1_3A"],
                    },
                    "scenarios": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "label": {
                                    "type": "string",
                                    "enum": ["ALCISTA", "NEUTRAL", "BAJISTA"],
                                },
                                "probability_pct": {"type": "number"},
                                "rationale": {"type": "string"},
                                "key_evidence_refs": {
                                    "type": "array",
                                    "items": {"type": "string"},
                                },
                            },
                            "required": [
                                "label",
                                "probability_pct",
                                "rationale",
                                "key_evidence_refs",
                            ],
                        },
                    },
                    "confidence_level": {
                        "type": "string",
                        "enum": ["BAJA", "MEDIA", "ALTA"],
                    },
                    "data_completeness_pct": {"type": "number"},
                },
                "required": [
                    "horizon",
                    "scenarios",
                    "confidence_level",
                    "data_completeness_pct",
                ],
            },
        },
        "classification": {
            "type": "string",
            "enum": ["REACCION_EMOCIONAL", "DETERIORO_FUNDAMENTAL", "INDETERMINADO"],
        },
        "classification_confidence_pct": {"type": "number"},
    },
    "required": ["horizons", "classification", "classification_confidence_pct"],
}


class _LLMAssetProjectionOutput(BaseModel):
    """Forma exacta de lo que le pedimos al LLM — deliberadamente sin `ticker`,
    `generated_at` ni `source_alert_id`: esos los fija el código, no el modelo.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    horizons: list[HorizonScenarios]
    classification: Literal[
        "REACCION_EMOCIONAL", "DETERIORO_FUNDAMENTAL", "INDETERMINADO"
    ]
    classification_confidence_pct: Decimal = Field(ge=0, le=100)


def _load_system_prompt() -> str:
    try:
        return _PROMPT_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(
            f"No se pudo leer el system prompt del Nodo 3 en {_PROMPT_PATH}."
        ) from exc


class GeminiScenarioEvaluator:
    def __init__(
        self, gemini_client: GeminiClient, *, system_prompt: str | None = None
    ) -> None:
        self._gemini = gemini_client
        self._system_prompt = system_prompt or _load_system_prompt()

    async def evaluate(
        self,
        asset: WatchedAsset,
        alert: MarketAlert,
        dossier: ResearchDossier,
        guardrail_feedback: GuardrailResult | None,
    ) -> AssetProjection:
        user_content = _build_user_content(asset, alert, dossier, guardrail_feedback)

        result = await self._gemini.generate_structured_json(
            system_instruction=self._system_prompt,
            user_content=user_content,
            response_schema=_RESPONSE_SCHEMA,
        )

        if result.status != DataStatus.OK or result.raw_json_text is None:
            logger.warning(
                "scenario_evaluation_degraded",
                extra={"ticker": asset.ticker, "reason": "gemini_call_failed"},
            )
            return _degraded_projection(
                asset,
                alert,
                reason=f"La llamada a Gemini falló (status={result.status.value}).",
            )

        try:
            parsed = json.loads(result.raw_json_text)
            # strict=False solo en esta frontera: JSON no tiene tipo Decimal nativo, así que
            # los números que Gemini devuelve llegan como int/float y necesitan coerción. El
            # resto del código sigue construyendo estos modelos en modo strict (.cursorrules §2).
            llm_output = _LLMAssetProjectionOutput.model_validate(parsed, strict=False)
        except (json.JSONDecodeError, ValidationError) as exc:
            logger.warning(
                "scenario_evaluation_output_invalid",
                extra={"ticker": asset.ticker, "error": str(exc)},
            )
            return _degraded_projection(
                asset,
                alert,
                reason="La respuesta del modelo no cumplió el esquema esperado.",
            )

        horizons = [
            _clamp_confidence_if_inconsistent(horizon)
            for horizon in llm_output.horizons
        ]

        return AssetProjection(
            ticker=asset.ticker,
            generated_at=datetime.now(timezone.utc),
            source_alert_id=alert.alert_id,
            horizons=horizons,
            classification=llm_output.classification,
            classification_confidence_pct=llm_output.classification_confidence_pct,
        )


def _clamp_confidence_if_inconsistent(horizon: HorizonScenarios) -> HorizonScenarios:
    """El código, no el LLM, es la autoridad final de que las probabilidades sumen 100
    (Spec.md §3.3: "esto se valida en código... no se confía en que el LLM sume bien").
    Una distribución inconsistente nunca se presenta con alta confianza.
    """

    total = sum(
        (scenario.probability_pct for scenario in horizon.scenarios), start=Decimal(0)
    )
    if abs(total - Decimal(100)) > _PROBABILITY_SUM_TOLERANCE:
        logger.warning(
            "horizon_probability_sum_inconsistent",
            extra={"horizon": horizon.horizon, "total": str(total)},
        )
        return horizon.model_copy(update={"confidence_level": "BAJA"})
    return horizon


def _degraded_projection(
    asset: WatchedAsset, alert: MarketAlert, *, reason: str
) -> AssetProjection:
    """Fallback cuando el LLM falla o su salida no es válida: distribución máximamente
    incierta (34/33/33, la más honesta posible ante ausencia total de señal), confianza BAJA
    y 0% de completitud — nunca se inventa una probabilidad con apariencia de certeza.
    """

    uninformative_scenarios = [
        ScenarioOutcome(label="ALCISTA", probability_pct=Decimal(34), rationale=reason),
        ScenarioOutcome(label="NEUTRAL", probability_pct=Decimal(33), rationale=reason),
        ScenarioOutcome(label="BAJISTA", probability_pct=Decimal(33), rationale=reason),
    ]

    return AssetProjection(
        ticker=asset.ticker,
        generated_at=datetime.now(timezone.utc),
        source_alert_id=alert.alert_id,
        horizons=[
            HorizonScenarios(
                horizon=horizon_label,
                scenarios=uninformative_scenarios,
                confidence_level="BAJA",
                data_completeness_pct=Decimal(0),
            )
            for horizon_label in _HORIZONS
        ],
        classification="INDETERMINADO",
        classification_confidence_pct=Decimal(0),
    )


def _build_user_content(
    asset: WatchedAsset,
    alert: MarketAlert,
    dossier: ResearchDossier,
    guardrail_feedback: GuardrailResult | None,
) -> str:
    financial_metrics_section = (
        dossier.financial_metrics.model_dump_json()
        if dossier.financial_metrics is not None
        else '"NO_DISPONIBLE"'
    )
    fds = (
        str(dossier.fundamental_deterioration_score)
        if dossier.fundamental_deterioration_score is not None
        else "null"
    )
    mrm = (
        str(dossier.market_reaction_magnitude)
        if dossier.market_reaction_magnitude is not None
        else "null"
    )

    sections = [
        f'<asset ticker="{asset.ticker}" asset_class="{asset.asset_class.value}" />',
        f"<market_alert>{alert.model_dump_json()}</market_alert>",
        f"<financial_metrics>{financial_metrics_section}</financial_metrics>",
        f"<research_dossier>{dossier.model_dump_json()}</research_dossier>",
        f'<quant_signals fds="{fds}" mrm="{mrm}" />',
    ]

    if guardrail_feedback is not None:
        sections.append(_format_guardrail_feedback(guardrail_feedback))

    return "\n".join(sections)


def _format_guardrail_feedback(feedback: GuardrailResult) -> str:
    failed_checks = [
        f"{finding.check_name}: {finding.detail}"
        for finding in feedback.findings
        if not finding.passed
    ]
    joined = "; ".join(failed_checks) if failed_checks else "sin detalle de fallos"
    return (
        "<guardrail_feedback>"
        f"El intento anterior fue rechazado por el Guardrail. Corrige específicamente: {joined}. "
        "Usa únicamente evidencia verificable citada en <research_dossier>."
        "</guardrail_feedback>"
    )
