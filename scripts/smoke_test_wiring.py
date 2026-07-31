"""Script de humo: corre el grafo LangGraph completo (Nodo 1 -> 2 -> 3 -> 4 -> 5) para NVDA
(equity, perfil avanzado) y BTC-USD (cripto, perfil principiante).

Uso:

    python -m scripts.smoke_test_wiring

Si `POLYGON_API_KEY`, `FMP_API_KEY`, `TAVILY_API_KEY`, `GEMINI_API_KEY` y las credenciales del
backend propio (`INTERNAL_BACKEND_BASE_URL` + opcionalmente `INTERNAL_BACKEND_API_KEY`) están
configuradas (ver `.env` / `core/config.py`), llama a las APIs reales. Si falta alguna, usa un
`httpx.MockTransport` determinístico para validar el wiring completo sin credenciales — útil
en CI o en un sandbox sin acceso de red a los proveedores. No hay Telegram/Discord: el Nodo 5
despacha hacia el backend propio (y opcionalmente FCM).
"""

from __future__ import annotations

import asyncio
import json
import logging

import httpx

from src.composition import build_ingestion_backed_dependencies
from src.core.config import settings
from src.core.state import AgentState
from src.ingestion.fmp_client import FMPClient
from src.ingestion.gemini_client import GeminiClient
from src.ingestion.polygon_client import PolygonClient
from src.ingestion.tavily_client import TavilyClient
from src.notification.internal_backend_client import InternalBackendClient
from src.processing.graph import build_graph
from src.validation.domain_models import AssetClass, UserProfile, WatchedAsset

logger = logging.getLogger(__name__)


def _mock_polygon_handler(request: httpx.Request) -> httpx.Response:
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
                    "todaysChangePerc": 8.10,
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


def _mock_fmp_handler(request: httpx.Request) -> httpx.Response:
    if "sec-filings-search" in request.url.path:
        return httpx.Response(
            200,
            json=[
                {
                    "filingDate": "2026-05-15",
                    "acceptedDate": "2026-05-15 16:30:00",
                    "link": "https://www.sec.gov/mock/filing",
                    "finalLink": "https://www.sec.gov/mock/filing/final",
                }
            ],
        )
    return httpx.Response(404, json={"error": "no usado en este smoke test"})


def _mock_tavily_handler(request: httpx.Request) -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "results": [
                {
                    "title": "Movimiento notable reportado en la nota de prensa",
                    "url": "https://example.com/news/1",
                    "content": (
                        "La acción/token tuvo un movimiento notable impulsado por catalizadores "
                        "recientes del sector. " * 5
                    ),
                    "published_date": "2026-07-30T09:00:00Z",
                }
            ]
        },
    )


def _mock_gemini_response() -> dict[str, object]:
    scenarios = [
        {
            "label": "ALCISTA",
            "probability_pct": 55,
            "rationale": "Momentum positivo tras el catalizador reciente.",
            "key_evidence_refs": [],
        },
        {
            "label": "NEUTRAL",
            "probability_pct": 25,
            "rationale": "Posible consolidación tras el movimiento.",
            "key_evidence_refs": [],
        },
        {
            "label": "BAJISTA",
            "probability_pct": 20,
            "rationale": "Riesgo de toma de ganancias de corto plazo.",
            "key_evidence_refs": [],
        },
    ]
    return {
        "horizons": [
            {
                "horizon": "CORTO_1_14D",
                "scenarios": scenarios,
                "confidence_level": "MEDIA",
                "data_completeness_pct": 60,
            },
            {
                "horizon": "MEDIANO_1_6M",
                "scenarios": scenarios,
                "confidence_level": "BAJA",
                "data_completeness_pct": 20,
            },
            {
                "horizon": "LARGO_1_3A",
                "scenarios": scenarios,
                "confidence_level": "BAJA",
                "data_completeness_pct": 20,
            },
        ],
        "classification": "REACCION_EMOCIONAL",
        "classification_confidence_pct": 55,
    }


def _mock_gemini_handler(request: httpx.Request) -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "candidates": [
                {
                    "content": {
                        "parts": [{"text": json.dumps(_mock_gemini_response())}]
                    },
                    "finishReason": "STOP",
                }
            ]
        },
    )


def _mock_internal_backend_handler(request: httpx.Request) -> httpx.Response:
    return httpx.Response(200, json={"alert_id": "db-mock-001"})


def _build_clients() -> tuple[
    PolygonClient, FMPClient, TavilyClient, GeminiClient, InternalBackendClient, bool
]:
    if (
        settings.polygon_api_key
        and settings.fmp_api_key
        and settings.tavily_api_key
        and settings.gemini_api_key
    ):
        polygon = PolygonClient(
            settings.polygon_api_key.get_secret_value(),
            base_url=settings.polygon_base_url,
        )
        fmp = FMPClient(
            settings.fmp_api_key.get_secret_value(), base_url=settings.fmp_base_url
        )
        tavily = TavilyClient(
            settings.tavily_api_key.get_secret_value(),
            base_url=settings.tavily_base_url,
        )
        gemini = GeminiClient(
            settings.gemini_api_key.get_secret_value(),
            base_url=settings.gemini_base_url,
            model=settings.gemini_model,
        )
        backend = InternalBackendClient(
            settings.internal_backend_base_url,
            dispatch_path=settings.internal_backend_dispatch_path,
            api_key=(
                settings.internal_backend_api_key.get_secret_value()
                if settings.internal_backend_api_key
                else None
            ),
        )
        return polygon, fmp, tavily, gemini, backend, True

    logger.warning(
        "no_real_api_keys_configured_using_mock_transport",
        extra={
            "hint": (
                "definí POLYGON_API_KEY/FMP_API_KEY/TAVILY_API_KEY/GEMINI_API_KEY "
                "para probar contra red real"
            )
        },
    )
    polygon = PolygonClient(
        "mock-key",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(_mock_polygon_handler),
            base_url="https://api.polygon.io",
        ),
    )
    fmp = FMPClient(
        "mock-key",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(_mock_fmp_handler),
            base_url="https://financialmodelingprep.com/stable",
        ),
    )
    tavily = TavilyClient(
        "mock-key",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(_mock_tavily_handler),
            base_url="https://api.tavily.com",
        ),
    )
    gemini = GeminiClient(
        "mock-key",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(_mock_gemini_handler),
            base_url="https://generativelanguage.googleapis.com/v1beta",
        ),
    )
    backend = InternalBackendClient(
        "https://backend.internal",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(_mock_internal_backend_handler),
            base_url="https://backend.internal",
        ),
    )
    return polygon, fmp, tavily, gemini, backend, False


async def main() -> None:
    logging.basicConfig(level=logging.INFO)
    polygon, fmp, tavily, gemini, backend, using_real_network = _build_clients()

    deps = build_ingestion_backed_dependencies(
        polygon, fmp, tavily, gemini_client=gemini, internal_backend_client=backend
    )
    graph = build_graph(deps)

    print(f"Usando red real: {using_real_network}\n")

    try:
        cases = (
            ("NVDA", AssetClass.EQUITY, UserProfile.FICHA_INTELIGENCIA_PROFUNDA),
            ("BTC-USD", AssetClass.CRYPTO, UserProfile.TRADUCTOR_FINANCIERO),
        )
        for ticker, asset_class, user_profile in cases:
            print(f"=== {ticker} ({user_profile.value}) ===")
            asset = WatchedAsset(ticker=ticker, asset_class=asset_class)
            result = await graph.ainvoke(
                AgentState(watched_asset=asset, user_profile=user_profile)
            )

            payload = result.get("notification_payload")
            if payload is None:
                print("Sin notificación (sin alerta detectada).\n")
                continue

            print(
                f"push_dispatched={payload.push_dispatched} "
                f"alert_db_id={payload.alert_db_id} "
                f"urgency_level={payload.urgency_level.value} "
                f"default_view={payload.default_view} "
                f"degraded_raw_data_only={payload.degraded_raw_data_only}"
            )
            print(f"title: {payload.title}")
            print(f"short_summary: {payload.short_summary}")
            print(f"action_url: {payload.action_url}")
            print(f"technical_narrative: {payload.technical_narrative.headline}")
            for line in payload.technical_narrative.horizon_explanations:
                print(f"  - {line}")
            print(f"beginner_narrative: {payload.beginner_narrative.headline}")
            for line in payload.beginner_narrative.horizon_explanations:
                print(f"  - {line}")
            print()
    finally:
        await polygon.aclose()
        await fmp.aclose()
        await tavily.aclose()
        await gemini.aclose()
        await backend.aclose()


if __name__ == "__main__":
    asyncio.run(main())
