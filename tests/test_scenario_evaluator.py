"""Tests del Nodo 3 (`GeminiScenarioEvaluator`): camino feliz (JSON válido -> AssetProjection),
fallback degradado ante fallo de red, fallback degradado ante salida que no valida contra el
esquema esperado, y downgrade de confianza cuando las probabilidades no suman 100.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from decimal import Decimal
from uuid import uuid4

import httpx

from src.ingestion.gemini_client import GeminiClient
from src.processing.scenario_evaluator import GeminiScenarioEvaluator
from src.validation.domain_models import (
    AlertSeverity,
    AlertTriggerType,
    AssetClass,
    MarketAlert,
    ResearchDossier,
    WatchedAsset,
)

_TEST_SYSTEM_PROMPT = "Eres un analista financiero de prueba."


def _make_asset() -> WatchedAsset:
    return WatchedAsset(ticker="NVDA", asset_class=AssetClass.EQUITY)


def _make_alert() -> MarketAlert:
    return MarketAlert(
        alert_id=str(uuid4()),
        ticker="NVDA",
        asset_class=AssetClass.EQUITY,
        trigger_type=AlertTriggerType.PRICE_MOVE,
        severity=AlertSeverity.HIGH,
        detected_at=datetime.now(timezone.utc),
        trigger_value=Decimal("8.72"),
        threshold_breached=Decimal("6.0"),
        requires_deep_research=True,
    )


def _make_dossier() -> ResearchDossier:
    return ResearchDossier(
        ticker="NVDA",
        generated_at=datetime.now(timezone.utc),
        summary="Alerta HIGH detectada. 1 noticia recuperada.",
    )


_VALID_LLM_RESPONSE: dict[str, object] = {
    "horizons": [
        {
            "horizon": "CORTO_1_14D",
            "scenarios": [
                {
                    "label": "ALCISTA",
                    "probability_pct": 55,
                    "rationale": "Momentum positivo tras earnings.",
                    "key_evidence_refs": ["tavily:1"],
                },
                {
                    "label": "NEUTRAL",
                    "probability_pct": 25,
                    "rationale": "Posible consolidación.",
                    "key_evidence_refs": [],
                },
                {
                    "label": "BAJISTA",
                    "probability_pct": 20,
                    "rationale": "Riesgo de toma de ganancias.",
                    "key_evidence_refs": [],
                },
            ],
            "confidence_level": "MEDIA",
            "data_completeness_pct": 70,
        },
        {
            "horizon": "MEDIANO_1_6M",
            "scenarios": [
                {
                    "label": "ALCISTA",
                    "probability_pct": 50,
                    "rationale": "Guidance sólido.",
                    "key_evidence_refs": [],
                },
                {
                    "label": "NEUTRAL",
                    "probability_pct": 30,
                    "rationale": "Incertidumbre macro.",
                    "key_evidence_refs": [],
                },
                {
                    "label": "BAJISTA",
                    "probability_pct": 20,
                    "rationale": "Compresión de márgenes posible.",
                    "key_evidence_refs": [],
                },
            ],
            "confidence_level": "MEDIA",
            "data_completeness_pct": 60,
        },
        {
            "horizon": "LARGO_1_3A",
            "scenarios": [
                {
                    "label": "ALCISTA",
                    "probability_pct": 60,
                    "rationale": "Moat competitivo en GPUs de IA.",
                    "key_evidence_refs": [],
                },
                {
                    "label": "NEUTRAL",
                    "probability_pct": 25,
                    "rationale": "Competencia creciente.",
                    "key_evidence_refs": [],
                },
                {
                    "label": "BAJISTA",
                    "probability_pct": 15,
                    "rationale": "Riesgo regulatorio.",
                    "key_evidence_refs": [],
                },
            ],
            "confidence_level": "BAJA",
            "data_completeness_pct": 40,
        },
    ],
    "classification": "REACCION_EMOCIONAL",
    "classification_confidence_pct": 65,
}


def _gemini_response_with_text(text: str) -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "candidates": [
                {"content": {"parts": [{"text": text}]}, "finishReason": "STOP"},
            ]
        },
    )


async def test_valid_gemini_response_produces_asset_projection() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return _gemini_response_with_text(json.dumps(_VALID_LLM_RESPONSE))

    gemini = GeminiClient(
        "test-key",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(handler),
            base_url="https://generativelanguage.googleapis.com/v1beta",
        ),
    )
    evaluator = GeminiScenarioEvaluator(gemini, system_prompt=_TEST_SYSTEM_PROMPT)

    try:
        projection = await evaluator.evaluate(
            _make_asset(), _make_alert(), _make_dossier(), None
        )

        assert projection.ticker == "NVDA"
        assert projection.classification == "REACCION_EMOCIONAL"
        assert len(projection.horizons) == 3
        for horizon in projection.horizons:
            total = sum(s.probability_pct for s in horizon.scenarios)
            assert abs(total - Decimal(100)) <= Decimal("0.5")
    finally:
        await gemini.aclose()


async def test_gemini_failure_produces_degraded_projection() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(503, json={"error": "unavailable"})

    gemini = GeminiClient(
        "test-key",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(handler),
            base_url="https://generativelanguage.googleapis.com/v1beta",
        ),
        max_retry_attempts=1,
    )
    evaluator = GeminiScenarioEvaluator(gemini, system_prompt=_TEST_SYSTEM_PROMPT)

    try:
        projection = await evaluator.evaluate(
            _make_asset(), _make_alert(), _make_dossier(), None
        )

        assert projection.classification == "INDETERMINADO"
        assert projection.classification_confidence_pct == Decimal(0)
        for horizon in projection.horizons:
            assert horizon.confidence_level == "BAJA"
            assert horizon.data_completeness_pct == Decimal(0)
            total = sum(s.probability_pct for s in horizon.scenarios)
            assert total == Decimal(100)
    finally:
        await gemini.aclose()


async def test_malformed_gemini_output_produces_degraded_projection() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return _gemini_response_with_text(json.dumps({"unexpected": "shape"}))

    gemini = GeminiClient(
        "test-key",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(handler),
            base_url="https://generativelanguage.googleapis.com/v1beta",
        ),
    )
    evaluator = GeminiScenarioEvaluator(gemini, system_prompt=_TEST_SYSTEM_PROMPT)

    try:
        projection = await evaluator.evaluate(
            _make_asset(), _make_alert(), _make_dossier(), None
        )

        assert projection.classification == "INDETERMINADO"
    finally:
        await gemini.aclose()


async def test_inconsistent_probability_sum_is_downgraded_to_low_confidence() -> None:
    bad_response = json.loads(json.dumps(_VALID_LLM_RESPONSE))
    bad_response["horizons"][0]["scenarios"][0]["probability_pct"] = 90
    bad_response["horizons"][0]["confidence_level"] = "ALTA"

    def handler(request: httpx.Request) -> httpx.Response:
        return _gemini_response_with_text(json.dumps(bad_response))

    gemini = GeminiClient(
        "test-key",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(handler),
            base_url="https://generativelanguage.googleapis.com/v1beta",
        ),
    )
    evaluator = GeminiScenarioEvaluator(gemini, system_prompt=_TEST_SYSTEM_PROMPT)

    try:
        projection = await evaluator.evaluate(
            _make_asset(), _make_alert(), _make_dossier(), None
        )

        short_term = next(h for h in projection.horizons if h.horizon == "CORTO_1_14D")
        assert short_term.confidence_level == "BAJA"
    finally:
        await gemini.aclose()
