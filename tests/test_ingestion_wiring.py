"""Test de wiring: valida que `build_ingestion_backed_dependencies` conecte correctamente
Polygon/FMP/Tavily a los puertos `MarketDataProvider`/`DeepResearchProvider` que consume el
grafo (Nodo 1 y Nodo 2), sin red real (httpx.MockTransport).
"""

from __future__ import annotations

import httpx

from src.composition import build_ingestion_backed_dependencies
from src.core.dependencies import (
    GuardrailAuditor,
    NotificationDispatcher,
    ScenarioEvaluator,
)
from src.ingestion.fmp_client import FMPClient
from src.ingestion.polygon_client import PolygonClient
from src.ingestion.tavily_client import TavilyClient
from src.validation.domain_models import (
    AssetClass,
    AssetProjection,
    GuardrailResult,
    MarketAlert,
    NotificationPayload,
    ResearchDossier,
    UserProfile,
    WatchedAsset,
)


class _UnusedScenarioEvaluator:
    async def evaluate(
        self,
        asset: WatchedAsset,
        alert: MarketAlert,
        dossier: ResearchDossier,
        guardrail_feedback: GuardrailResult | None,
    ) -> AssetProjection:
        raise AssertionError("no debería invocarse en este test de wiring")


class _UnusedGuardrailAuditor:
    async def audit(
        self, projection: AssetProjection, dossier: ResearchDossier, alert: MarketAlert
    ) -> GuardrailResult:
        raise AssertionError("no debería invocarse en este test de wiring")


class _UnusedNotificationDispatcher:
    async def render_and_send(
        self,
        asset: WatchedAsset,
        user_profile: UserProfile,
        alert: MarketAlert | None,
        projection: AssetProjection | None,
        degraded_raw_data_only: bool,
    ) -> NotificationPayload:
        raise AssertionError("no debería invocarse en este test de wiring")


def _polygon_handler(request: httpx.Request) -> httpx.Response:
    if "crypto" in request.url.path:
        return httpx.Response(
            200,
            json={
                "ticker": {
                    "day": {
                        "c": 65000.0,
                        "o": 63000.0,
                        "h": 65500.0,
                        "l": 62800.0,
                        "v": 25000,
                    },
                    "prevDay": {"c": 63200.0},
                    "todaysChangePerc": 2.85,
                }
            },
        )
    return httpx.Response(
        200,
        json={
            "ticker": {
                "day": {
                    "c": 128.50,
                    "o": 118.0,
                    "h": 129.0,
                    "l": 117.5,
                    "v": 350_000_000,
                },
                "prevDay": {"c": 118.2},
                "todaysChangePerc": 8.72,
            }
        },
    )


def _fmp_handler(request: httpx.Request) -> httpx.Response:
    if "sec-filings-search" in request.url.path:
        return httpx.Response(
            200,
            json=[
                {"filingDate": "2026-05-15", "link": "https://www.sec.gov/mock/filing"}
            ],
        )
    return httpx.Response(404, json={"error": "no usado en este test"})


def _tavily_handler(request: httpx.Request) -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "results": [
                {
                    "title": "NVDA sube tras resultados",
                    "url": "https://example.com/news/nvda",
                    "content": "Contenido de la noticia " * 20,
                    "published_date": "2026-07-30T09:00:00Z",
                }
            ]
        },
    )


def _build_test_dependencies() -> tuple[
    PolygonClient,
    FMPClient,
    TavilyClient,
    ScenarioEvaluator,
    GuardrailAuditor,
    NotificationDispatcher,
]:
    polygon = PolygonClient(
        "test-key",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(_polygon_handler),
            base_url="https://api.polygon.io",
        ),
    )
    fmp = FMPClient(
        "test-key",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(_fmp_handler),
            base_url="https://financialmodelingprep.com/stable",
        ),
    )
    tavily = TavilyClient(
        "test-key",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(_tavily_handler),
            base_url="https://api.tavily.com",
        ),
    )
    return (
        polygon,
        fmp,
        tavily,
        _UnusedScenarioEvaluator(),
        _UnusedGuardrailAuditor(),
        _UnusedNotificationDispatcher(),
    )


async def test_equity_alert_triggers_deep_research_dossier() -> None:
    polygon, fmp, tavily, scenario_evaluator, guardrail, notifier = (
        _build_test_dependencies()
    )
    deps = build_ingestion_backed_dependencies(
        polygon,
        fmp,
        tavily,
        scenario_evaluator=scenario_evaluator,
        guardrail=guardrail,
        notifier=notifier,
    )

    try:
        asset = WatchedAsset(ticker="NVDA", asset_class=AssetClass.EQUITY)
        alert = await deps.market_data.fetch_snapshot_and_detect_alert(asset)

        assert alert is not None
        assert alert.severity.value in ("HIGH", "CRITICAL")
        assert alert.requires_deep_research is True

        dossier = await deps.deep_research.build_dossier(asset, alert)

        assert dossier.ticker == "NVDA"
        assert len(dossier.evidence) >= 1
        assert any(item.source_type == "NEWS" for item in dossier.evidence)
        assert any(item.source_type == "SEC_10K" for item in dossier.evidence)
    finally:
        await polygon.aclose()
        await fmp.aclose()
        await tavily.aclose()


async def test_crypto_small_move_produces_no_alert() -> None:
    polygon, fmp, tavily, scenario_evaluator, guardrail, notifier = (
        _build_test_dependencies()
    )
    deps = build_ingestion_backed_dependencies(
        polygon,
        fmp,
        tavily,
        scenario_evaluator=scenario_evaluator,
        guardrail=guardrail,
        notifier=notifier,
    )

    try:
        asset = WatchedAsset(ticker="BTC-USD", asset_class=AssetClass.CRYPTO)
        alert = await deps.market_data.fetch_snapshot_and_detect_alert(asset)

        assert alert is None
    finally:
        await polygon.aclose()
        await fmp.aclose()
        await tavily.aclose()
