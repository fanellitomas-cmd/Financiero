"""Nodo 4 — Guardrail / Auditoría de Alucinaciones (Spec.md §3.4). Implementa
`GuardrailAuditor` con chequeos determinísticos sobre el `AssetProjection` del Nodo 3, sin
una segunda llamada a un LLM: compara sus cifras y citas contra el `MarketAlert` y el
`ResearchDossier` ya verificados, y detecta contradicciones entre la etiqueta de sentimiento
de cada escenario y su propio razonamiento.

Es un guardrail heurístico, no un verificador semántico completo: favorece deliberadamente un
bajo índice de falsos positivos (solo audita números con punto decimal — enteros sueltos como
años o conteos generan demasiado ruido — y un set acotado de palabras clave de contradicción)
por sobre una cobertura exhaustiva. Una versión más fuerte podría agregar el segundo pase de
LLM "verificador" que describe `prompts/analyst_system_prompt.md` §3.4; no se hace aquí para no
introducir una segunda fuente de alucinación que este propio módulo no pueda auditar.
"""

from __future__ import annotations

import logging
import re
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation

from src.validation.domain_models import (
    AssetProjection,
    GuardrailAction,
    GuardrailResult,
    MarketAlert,
    MetricValue,
    ResearchDossier,
)

logger = logging.getLogger(__name__)

_PROBABILITY_SUM_TOLERANCE = Decimal("0.5")
_LOW_COMPLETENESS_THRESHOLD = Decimal(50)
_DECIMAL_NUMBER_PATTERN = re.compile(r"\d+[.,]\d+")

_WEIGHT_CITATION_GROUNDING = 0.25
_WEIGHT_PROBABILITY_SUM = 0.15
_WEIGHT_NUMERIC_GROUNDING = 0.30
_WEIGHT_NARRATIVE_CONTRADICTION = 0.40
_WEIGHT_CONFIDENCE_SANITY = 0.15

# Ejemplo del propio requerimiento: una etiqueta ALCISTA no puede convivir con un razonamiento
# que describa a la empresa al borde de la quiebra, y viceversa para BAJISTA + dominancia total.
_DISTRESS_KEYWORDS = (
    "quiebra",
    "bancarrota",
    "insolvencia",
    "colapso total",
    "cesación de pagos",
    "default inminente",
    "liquidación forzosa",
)
_DOMINANCE_KEYWORDS = (
    "dominancia absoluta",
    "monopolio total",
    "sin competencia real",
    "crecimiento imparable",
)


class HeuristicGuardrailAuditor:
    def __init__(self, *, numeric_tolerance_pct: Decimal = Decimal("1.0")) -> None:
        self._numeric_tolerance_pct = numeric_tolerance_pct

    async def audit(
        self, projection: AssetProjection, dossier: ResearchDossier, alert: MarketAlert
    ) -> GuardrailResult:
        issues: list[str] = []
        weighted_score = 0.0
        has_structural_issue = False

        known_ref_ids = {item.ref_id for item in dossier.evidence}
        known_numbers = _collect_known_numbers(dossier, alert)

        for horizon in projection.horizons:
            citation_flagged = False
            numeric_flagged = False

            total = sum(
                (s.probability_pct for s in horizon.scenarios), start=Decimal(0)
            )
            if abs(total - Decimal(100)) > _PROBABILITY_SUM_TOLERANCE:
                issues.append(
                    f"{horizon.horizon}: las probabilidades suman {total}%, no 100%."
                )
                weighted_score += _WEIGHT_PROBABILITY_SUM

            if (
                horizon.confidence_level == "ALTA"
                and horizon.data_completeness_pct < _LOW_COMPLETENESS_THRESHOLD
            ):
                issues.append(
                    f"{horizon.horizon}: declara confianza ALTA con solo "
                    f"{horizon.data_completeness_pct}% de completitud de datos."
                )
                weighted_score += _WEIGHT_CONFIDENCE_SANITY

            for scenario in horizon.scenarios:
                for ref in scenario.key_evidence_refs:
                    if ref not in known_ref_ids:
                        issues.append(
                            f"{horizon.horizon}/{scenario.label}: cita '{ref}' no existe en "
                            "la evidencia del dossier."
                        )
                        citation_flagged = True

                for number in _extract_numbers(scenario.rationale):
                    if not _matches_any(
                        number, known_numbers, self._numeric_tolerance_pct
                    ):
                        issues.append(
                            f"{horizon.horizon}/{scenario.label}: la cifra {number} en el "
                            "razonamiento no aparece en el contexto verificado."
                        )
                        numeric_flagged = True

                contradiction = _find_contradictory_keyword(
                    scenario.label, scenario.rationale
                )
                if contradiction is not None:
                    issues.append(
                        f"{horizon.horizon}/{scenario.label}: el razonamiento usa el término "
                        f"'{contradiction}', que contradice la etiqueta de sentimiento asignada."
                    )
                    has_structural_issue = True

            if citation_flagged:
                weighted_score += _WEIGHT_CITATION_GROUNDING
            if numeric_flagged:
                weighted_score += _WEIGHT_NUMERIC_GROUNDING

        if has_structural_issue:
            weighted_score += _WEIGHT_NARRATIVE_CONTRADICTION

        hallucination_score = min(weighted_score, 1.0)
        is_valid = not issues

        if is_valid:
            recommended_action = GuardrailAction.PASS
        elif has_structural_issue:
            # Una contradicción narrativa es un error de razonamiento del LLM, no un vacío de
            # datos: más investigación no lo corrige de forma confiable, así que se aborta en
            # vez de gastar un ciclo extra de LLM sobre el mismo problema.
            recommended_action = GuardrailAction.ABORT
        else:
            recommended_action = GuardrailAction.RE_RUN_RESEARCH

        if issues:
            logger.warning(
                "guardrail_flagged_projection",
                extra={
                    "ticker": projection.ticker,
                    "hallucination_score": hallucination_score,
                    "recommended_action": recommended_action.value,
                    "issue_count": len(issues),
                },
            )

        return GuardrailResult(
            is_valid=is_valid,
            hallucination_score=hallucination_score,
            flagged_issues=issues,
            recommended_action=recommended_action,
            evaluated_at=datetime.now(timezone.utc),
        )


def _extract_numbers(text: str) -> list[Decimal]:
    numbers: list[Decimal] = []
    for match in _DECIMAL_NUMBER_PATTERN.finditer(text):
        normalized = match.group(0).replace(",", ".")
        try:
            numbers.append(Decimal(normalized))
        except InvalidOperation:
            continue
    return numbers


def _collect_known_numbers(
    dossier: ResearchDossier, alert: MarketAlert
) -> list[Decimal]:
    numbers: list[Decimal] = []

    if alert.trigger_value is not None:
        numbers.append(alert.trigger_value)
    if alert.threshold_breached is not None:
        numbers.append(alert.threshold_breached)
    if dossier.fundamental_deterioration_score is not None:
        numbers.append(dossier.fundamental_deterioration_score)
    if dossier.market_reaction_magnitude is not None:
        numbers.append(dossier.market_reaction_magnitude)

    if dossier.financial_metrics is not None:
        for field_name in dossier.financial_metrics.__class__.model_fields:
            value = getattr(dossier.financial_metrics, field_name)
            if isinstance(value, MetricValue) and value.value is not None:
                numbers.append(value.value)

    for item in dossier.evidence:
        numbers.extend(_extract_numbers(item.excerpt))

    return numbers


def _matches_any(
    number: Decimal, known_numbers: list[Decimal], tolerance_pct: Decimal
) -> bool:
    for known in known_numbers:
        tolerance = max(abs(known) * tolerance_pct / Decimal(100), Decimal("0.05"))
        if abs(number - known) <= tolerance:
            return True
    return False


def _find_contradictory_keyword(label: str, rationale: str) -> str | None:
    lowered = rationale.lower()
    keywords: tuple[str, ...]
    if label == "ALCISTA":
        keywords = _DISTRESS_KEYWORDS
    elif label == "BAJISTA":
        keywords = _DOMINANCE_KEYWORDS
    else:
        return None

    for keyword in keywords:
        if keyword in lowered:
            return keyword
    return None
