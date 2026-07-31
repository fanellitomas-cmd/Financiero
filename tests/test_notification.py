"""Tests del Nodo 5 nativo: construcción del payload (perfil avanzado vs. principiante,
degradado, informativo) y el dispatcher end-to-end contra el backend propio y FCM mockeados
(httpx.MockTransport, sin red real, sin terceros tipo Telegram/Discord).
"""

from __future__ import annotations

from datetime import datetime, timezone
from decimal import Decimal
from uuid import uuid4

import httpx

from src.notification.dispatcher import NativePushDispatcher
from src.notification.fcm_client import FCMClient
from src.notification.internal_backend_client import InternalBackendClient
from src.notification.payload_builder import build_push_payload
from src.validation.domain_models import (
    AlertSeverity,
    AlertTriggerType,
    AssetClass,
    AssetProjection,
    HorizonScenarios,
    MarketAlert,
    ScenarioOutcome,
    UserProfile,
    WatchedAsset,
)

_ACTION_URL_TEMPLATE = "financiero://asset/{ticker}"


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


def _make_projection() -> AssetProjection:
    scenarios = [
        ScenarioOutcome(
            label="ALCISTA", probability_pct=Decimal(55), rationale="Momentum."
        ),
        ScenarioOutcome(
            label="NEUTRAL", probability_pct=Decimal(25), rationale="Neutral."
        ),
        ScenarioOutcome(
            label="BAJISTA", probability_pct=Decimal(20), rationale="Riesgo."
        ),
    ]
    return AssetProjection(
        ticker="NVDA",
        generated_at=datetime.now(timezone.utc),
        source_alert_id=str(uuid4()),
        horizons=[
            HorizonScenarios(
                horizon="CORTO_1_14D",
                scenarios=scenarios,
                confidence_level="MEDIA",
                data_completeness_pct=Decimal(60),
            ),
            HorizonScenarios(
                horizon="LARGO_1_3A",
                scenarios=scenarios,
                confidence_level="BAJA",
                data_completeness_pct=Decimal(20),
            ),
        ],
        classification="REACCION_EMOCIONAL",
        classification_confidence_pct=Decimal(65),
    )


def test_payload_includes_both_narratives_regardless_of_profile() -> None:
    payload = build_push_payload(
        asset=WatchedAsset(ticker="NVDA", asset_class=AssetClass.EQUITY),
        user_profile=UserProfile.TRADUCTOR_FINANCIERO,
        alert=_make_alert(),
        projection=_make_projection(),
        degraded_raw_data_only=False,
        action_url_template=_ACTION_URL_TEMPLATE,
    )

    assert payload.default_view == "beginner"
    # ambas narrativas siempre presentes, para que la app pueda alternar sin un nuevo push
    assert "55" in " ".join(payload.technical_narrative.horizon_explanations)
    assert "55" not in payload.beginner_narrative.headline
    assert "55" not in " ".join(payload.beginner_narrative.horizon_explanations)
    assert payload.full_analysis_json is not None
    assert payload.asset_type == "stock"
    assert payload.action_url == "financiero://asset/NVDA"
    assert payload.urgency_level == AlertSeverity.HIGH


def test_payload_advanced_profile_defaults_to_technical_view() -> None:
    payload = build_push_payload(
        asset=WatchedAsset(ticker="BTC-USD", asset_class=AssetClass.CRYPTO),
        user_profile=UserProfile.FICHA_INTELIGENCIA_PROFUNDA,
        alert=_make_alert(),
        projection=_make_projection(),
        degraded_raw_data_only=False,
        action_url_template=_ACTION_URL_TEMPLATE,
    )

    assert payload.default_view == "technical"
    assert payload.asset_type == "crypto"


def test_payload_degraded_has_no_full_analysis() -> None:
    payload = build_push_payload(
        asset=WatchedAsset(ticker="NVDA", asset_class=AssetClass.EQUITY),
        user_profile=UserProfile.FICHA_INTELIGENCIA_PROFUNDA,
        alert=_make_alert(),
        projection=None,
        degraded_raw_data_only=True,
        action_url_template=_ACTION_URL_TEMPLATE,
    )

    assert payload.full_analysis_json is None
    assert payload.degraded_raw_data_only is True
    assert "Guardrail" in payload.technical_narrative.headline


def test_payload_informational_has_no_alert_severity_defaults_to_low() -> None:
    payload = build_push_payload(
        asset=WatchedAsset(ticker="NVDA", asset_class=AssetClass.EQUITY),
        user_profile=UserProfile.FICHA_INTELIGENCIA_PROFUNDA,
        alert=None,
        projection=None,
        degraded_raw_data_only=False,
        action_url_template=_ACTION_URL_TEMPLATE,
    )

    assert payload.urgency_level == AlertSeverity.LOW
    assert payload.full_analysis_json is None


async def test_dispatcher_registers_with_internal_backend_and_reports_alert_id() -> (
    None
):
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"alert_id": "db-123"})

    backend = InternalBackendClient(
        "https://backend.internal",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(handler), base_url="https://backend.internal"
        ),
    )
    dispatcher = NativePushDispatcher(internal_backend_client=backend)

    try:
        payload = await dispatcher.render_and_send(
            WatchedAsset(ticker="NVDA", asset_class=AssetClass.EQUITY),
            UserProfile.FICHA_INTELIGENCIA_PROFUNDA,
            _make_alert(),
            _make_projection(),
            False,
        )
        assert payload.push_dispatched is True
        assert payload.alert_db_id == "db-123"
    finally:
        await backend.aclose()


async def test_dispatcher_also_sends_to_fcm_when_configured() -> None:
    def backend_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"alert_id": "db-123"})

    def fcm_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"name": "projects/x/messages/999"})

    backend = InternalBackendClient(
        "https://backend.internal",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(backend_handler),
            base_url="https://backend.internal",
        ),
    )
    fcm = FCMClient(
        "my-project",
        "fake-access-token",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(fcm_handler),
            base_url="https://fcm.googleapis.com/v1",
        ),
    )
    dispatcher = NativePushDispatcher(internal_backend_client=backend, fcm_client=fcm)

    try:
        payload = await dispatcher.render_and_send(
            WatchedAsset(ticker="NVDA", asset_class=AssetClass.EQUITY),
            UserProfile.FICHA_INTELIGENCIA_PROFUNDA,
            _make_alert(),
            _make_projection(),
            False,
        )
        assert payload.push_dispatched is True
        assert payload.alert_db_id == "db-123"
    finally:
        await backend.aclose()
        await fcm.aclose()


async def test_dispatcher_reports_not_dispatched_when_backend_fails_and_no_fcm() -> (
    None
):
    def failing_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(503, json={"error": "unavailable"})

    backend = InternalBackendClient(
        "https://backend.internal",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(failing_handler),
            base_url="https://backend.internal",
        ),
        max_retry_attempts=1,
    )
    dispatcher = NativePushDispatcher(internal_backend_client=backend)

    try:
        payload = await dispatcher.render_and_send(
            WatchedAsset(ticker="NVDA", asset_class=AssetClass.EQUITY),
            UserProfile.FICHA_INTELIGENCIA_PROFUNDA,
            _make_alert(),
            _make_projection(),
            False,
        )
        assert payload.push_dispatched is False
        assert payload.alert_db_id is None
    finally:
        await backend.aclose()


async def test_fcm_still_marks_dispatched_when_backend_fails() -> None:
    def failing_backend_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(503, json={"error": "unavailable"})

    def fcm_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"name": "projects/x/messages/999"})

    backend = InternalBackendClient(
        "https://backend.internal",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(failing_backend_handler),
            base_url="https://backend.internal",
        ),
        max_retry_attempts=1,
    )
    fcm = FCMClient(
        "my-project",
        "fake-access-token",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(fcm_handler),
            base_url="https://fcm.googleapis.com/v1",
        ),
    )
    dispatcher = NativePushDispatcher(internal_backend_client=backend, fcm_client=fcm)

    try:
        payload = await dispatcher.render_and_send(
            WatchedAsset(ticker="NVDA", asset_class=AssetClass.EQUITY),
            UserProfile.FICHA_INTELIGENCIA_PROFUNDA,
            _make_alert(),
            _make_projection(),
            False,
        )
        assert payload.push_dispatched is True
        assert payload.alert_db_id is None, "el backend falló; FCM no da un alert_db_id"
    finally:
        await backend.aclose()
        await fcm.aclose()
