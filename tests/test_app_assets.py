"""Tests de `GET /api/v1/assets/{ticker}` (Ficha on-demand) y de
`AgentRunnerService.get_or_compute_payload`: usa el caché de `AlertHistory` si es reciente,
corre el grafo sincrónicamente si no, y nunca llama a proveedores reales — el grafo se
ejercita con dependencias falsas mínimas (`RuntimeGraphDependencies`), ruteando
`requires_deep_research=False` para no necesitar los Nodos 2/3/4 (ver
`src/processing/nodes/ingest_and_filter.py::route_after_ingestion`).
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import httpx
import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.alert_history import AlertHistory
from app.models.enums import AssetType
from app.services.agent_runner_service import (
    AgentRunnerService,
    AssetIntelligenceUnavailableError,
)
from app.services.push_service import PushNotificationService
from src.composition import RuntimeGraphDependencies
from src.validation.domain_models import (
    AlertSeverity,
    AlertTriggerType,
    AnalysisNarrative,
    AssetClass,
    AssetProjection,
    GuardrailResult,
    MarketAlert,
    PushNotificationPayload,
    ResearchDossier,
    UserProfile,
    WatchedAsset,
)


class _UnusedDeepResearchProvider:
    """`requires_deep_research=False` rutea Nodo 1 -> Nodo 5 directo (ver
    `route_after_ingestion`), así que si esto se invoca, el grafo tomó una rama que no
    debería para este test.
    """

    async def build_dossier(
        self, asset: WatchedAsset, alert: MarketAlert
    ) -> ResearchDossier:
        raise AssertionError("deep_research no debería invocarse en este test")


class _UnusedScenarioEvaluator:
    async def evaluate(
        self,
        asset: WatchedAsset,
        alert: MarketAlert,
        dossier: ResearchDossier,
        guardrail_feedback: GuardrailResult | None,
    ) -> AssetProjection:
        raise AssertionError("scenario_evaluator no debería invocarse en este test")


class _UnusedGuardrailAuditor:
    async def audit(
        self, projection: AssetProjection, dossier: ResearchDossier, alert: MarketAlert
    ) -> GuardrailResult:
        raise AssertionError("guardrail no debería invocarse en este test")


class _FakeMarketDataProvider:
    def __init__(self, alert: MarketAlert | None) -> None:
        self._alert = alert

    async def fetch_snapshot_and_detect_alert(
        self, asset: WatchedAsset
    ) -> MarketAlert | None:
        return self._alert


class _ExplosiveMarketDataProvider:
    """Para probar que un cache hit reciente NO corre el motor: si esto se invoca, el test
    falla con un `AssertionError` en vez de silenciosamente ejecutar el grafo de más.
    """

    async def fetch_snapshot_and_detect_alert(
        self, asset: WatchedAsset
    ) -> MarketAlert | None:
        raise AssertionError("no debería invocarse al motor: hay un cache reciente")


class _FakeNotificationDispatcher:
    def __init__(self, payload: PushNotificationPayload) -> None:
        self._payload = payload

    async def render_and_send(
        self,
        asset: WatchedAsset,
        user_profile: UserProfile,
        alert: MarketAlert | None,
        projection: AssetProjection | None,
        degraded_raw_data_only: bool,
    ) -> PushNotificationPayload:
        return self._payload


def _market_alert(ticker: str, *, requires_deep_research: bool = False) -> MarketAlert:
    return MarketAlert(
        alert_id=str(uuid.uuid4()),
        ticker=ticker,
        asset_class=AssetClass.EQUITY,
        trigger_type=AlertTriggerType.PRICE_MOVE,
        severity=AlertSeverity.LOW,
        detected_at=datetime.now(timezone.utc),
        trigger_value=Decimal("5.0"),
        threshold_breached=Decimal("3.0"),
        requires_deep_research=requires_deep_research,
        raw_context_snapshot={},
    )


def _payload(ticker: str) -> PushNotificationPayload:
    return PushNotificationPayload(
        notification_id=str(uuid.uuid4()),
        ticker=ticker,
        asset_type="stock",
        title="Alerta",
        short_summary="Resumen",
        technical_narrative=AnalysisNarrative(headline="Headline técnico"),
        beginner_narrative=AnalysisNarrative(headline="Headline simple"),
        default_view="technical",
        urgency_level=AlertSeverity.LOW,
        action_url=f"financiero://asset/{ticker}",
        timestamp=datetime.now(timezone.utc),
        push_dispatched=False,
        alert_db_id=None,
    )


def _build_agent_runner(
    session_factory: async_sessionmaker[AsyncSession],
    *,
    market_data: _FakeMarketDataProvider | _ExplosiveMarketDataProvider,
    notifier: _FakeNotificationDispatcher,
) -> AgentRunnerService:
    deps = RuntimeGraphDependencies(
        market_data=market_data,
        deep_research=_UnusedDeepResearchProvider(),
        scenario_evaluator=_UnusedScenarioEvaluator(),
        guardrail=_UnusedGuardrailAuditor(),
        notifier=notifier,
    )
    push_service = PushNotificationService(session_factory)
    return AgentRunnerService(deps, push_service, session_factory)


async def test_get_or_compute_payload_runs_graph_when_no_cache(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    payload = _payload("NVDA")
    runner = _build_agent_runner(
        db_session_factory,
        market_data=_FakeMarketDataProvider(_market_alert("NVDA")),
        notifier=_FakeNotificationDispatcher(payload),
    )

    result = await runner.get_or_compute_payload(
        "nvda", AssetType.STOCK, max_age=timedelta(minutes=15)
    )

    assert result.notification_id == payload.notification_id

    async with db_session_factory() as session:
        rows = (await session.execute(select(AlertHistory))).scalars().all()
    assert len(rows) == 1
    assert rows[0].ticker == "NVDA"


async def test_get_or_compute_payload_uses_recent_cache_without_running_engine(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    cached_payload = _payload("AAPL")
    async with db_session_factory() as session:
        session.add(
            AlertHistory(
                ticker="AAPL",
                payload_json=cached_payload.model_dump(mode="json"),
                urgency_level=cached_payload.urgency_level,
            )
        )
        await session.commit()

    runner = _build_agent_runner(
        db_session_factory,
        market_data=_ExplosiveMarketDataProvider(),
        notifier=_FakeNotificationDispatcher(_payload("SHOULD_NOT_BE_USED")),
    )

    result = await runner.get_or_compute_payload(
        "AAPL", AssetType.STOCK, max_age=timedelta(minutes=15)
    )

    assert result.notification_id == cached_payload.notification_id


async def test_get_or_compute_payload_ignores_stale_cache(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    stale_payload = _payload("MSFT")
    async with db_session_factory() as session:
        alert_row = AlertHistory(
            ticker="MSFT",
            payload_json=stale_payload.model_dump(mode="json"),
            urgency_level=stale_payload.urgency_level,
        )
        alert_row.created_at = datetime.now(timezone.utc) - timedelta(hours=1)
        session.add(alert_row)
        await session.commit()

    fresh_payload = _payload("MSFT")
    runner = _build_agent_runner(
        db_session_factory,
        market_data=_FakeMarketDataProvider(_market_alert("MSFT")),
        notifier=_FakeNotificationDispatcher(fresh_payload),
    )

    result = await runner.get_or_compute_payload(
        "MSFT", AssetType.STOCK, max_age=timedelta(minutes=15)
    )

    assert result.notification_id == fresh_payload.notification_id


async def test_get_or_compute_payload_raises_when_no_alert_detected(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    runner = _build_agent_runner(
        db_session_factory,
        market_data=_FakeMarketDataProvider(None),
        notifier=_FakeNotificationDispatcher(_payload("GOOG")),
    )

    with pytest.raises(AssetIntelligenceUnavailableError):
        await runner.get_or_compute_payload(
            "GOOG", AssetType.STOCK, max_age=timedelta(minutes=15)
        )


async def test_endpoint_returns_503_when_engine_not_configured(
    client: httpx.AsyncClient,
) -> None:
    await client.post(
        "/api/v1/auth/register",
        json={"email": "assets-user@example.com", "password": "supersecreta1"},
    )
    login = await client.post(
        "/api/v1/auth/login",
        json={"email": "assets-user@example.com", "password": "supersecreta1"},
    )
    headers = {"Authorization": f"Bearer {login.json()['access_token']}"}

    response = await client.get(
        "/api/v1/assets/NVDA", params={"asset_type": "STOCK"}, headers=headers
    )
    assert response.status_code == 503


async def test_endpoint_requires_auth(client: httpx.AsyncClient) -> None:
    response = await client.get("/api/v1/assets/NVDA", params={"asset_type": "STOCK"})
    assert response.status_code == 401
