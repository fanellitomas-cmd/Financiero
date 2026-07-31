"""Script de humo: verifica el wiring de ingesta -> `GraphDependencies` (Nodo 1 `market_data`,
Nodo 2 `deep_research`, Nodo 3 `scenario_evaluator`) con una consulta real de ticker.

Uso:

    python -m scripts.smoke_test_wiring

Si `POLYGON_API_KEY`, `FMP_API_KEY`, `TAVILY_API_KEY` y `GEMINI_API_KEY` están configuradas
(ver `.env` / `core/config.py`), llama a las APIs reales con NVDA (equity) y BTC-USD (cripto).
Si falta alguna, usa un `httpx.MockTransport` determinístico para validar el wiring sin
credenciales — útil en CI o en un sandbox sin acceso de red a los proveedores.

Los puertos de los Nodos 4/5 todavía no tienen implementación de producción; este script
nunca los invoca, así que los placeholders de abajo existen solo para poder construir un
`GraphDependencies` completo — no son parte de la librería.
"""

from __future__ import annotations

import asyncio
import json
import logging

import httpx

from src.composition import build_ingestion_backed_dependencies
from src.core.config import settings
from src.ingestion.fmp_client import FMPClient
from src.ingestion.gemini_client import GeminiClient
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

logger = logging.getLogger(__name__)


class _NotImplementedGuardrailAuditor:
    async def audit(
        self, projection: AssetProjection, dossier: ResearchDossier
    ) -> GuardrailResult:
        raise NotImplementedError("Nodo 4 (GuardrailAuditor) aún no implementado")


class _NotImplementedNotificationDispatcher:
    async def render_and_send(
        self,
        asset: WatchedAsset,
        user_profile: UserProfile,
        alert: MarketAlert | None,
        projection: AssetProjection | None,
        degraded_raw_data_only: bool,
    ) -> NotificationPayload:
        raise NotImplementedError("Nodo 5 (NotificationDispatcher) aún no implementado")


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
                    "title": "NVDA sube tras resultados trimestrales",
                    "url": "https://example.com/news/nvda-earnings",
                    "content": (
                        "Nvidia reportó ingresos por encima de lo esperado, impulsados por "
                        "la demanda de GPUs para entrenamiento de IA. " * 5
                    ),
                    "published_date": "2026-07-30T09:00:00Z",
                }
            ]
        },
    )


_MOCK_GEMINI_RESPONSE: dict[str, object] = {
    "horizons": [
        {
            "horizon": "CORTO_1_14D",
            "scenarios": [
                {
                    "label": "ALCISTA",
                    "probability_pct": 55,
                    "rationale": "Momentum positivo tras el reporte trimestral.",
                    "key_evidence_refs": ["tavily:0"],
                },
                {
                    "label": "NEUTRAL",
                    "probability_pct": 25,
                    "rationale": "Posible consolidación tras el salto de precio.",
                    "key_evidence_refs": [],
                },
                {
                    "label": "BAJISTA",
                    "probability_pct": 20,
                    "rationale": "Riesgo de toma de ganancias de corto plazo.",
                    "key_evidence_refs": [],
                },
            ],
            "confidence_level": "MEDIA",
            "data_completeness_pct": 60,
        },
        {
            "horizon": "MEDIANO_1_6M",
            "scenarios": [
                {
                    "label": "ALCISTA",
                    "probability_pct": 45,
                    "rationale": "Demanda sostenida de GPUs para IA.",
                    "key_evidence_refs": ["tavily:0"],
                },
                {
                    "label": "NEUTRAL",
                    "probability_pct": 35,
                    "rationale": "Incertidumbre macro y ciclo de gasto en datacenters.",
                    "key_evidence_refs": [],
                },
                {
                    "label": "BAJISTA",
                    "probability_pct": 20,
                    "rationale": "Fundamentales no disponibles en este dossier para confirmar guidance.",
                    "key_evidence_refs": [],
                },
            ],
            "confidence_level": "BAJA",
            "data_completeness_pct": 20,
        },
        {
            "horizon": "LARGO_1_3A",
            "scenarios": [
                {
                    "label": "ALCISTA",
                    "probability_pct": 50,
                    "rationale": "Posición dominante en aceleradores de IA.",
                    "key_evidence_refs": [],
                },
                {
                    "label": "NEUTRAL",
                    "probability_pct": 30,
                    "rationale": "Entrada de competidores en el mediano plazo.",
                    "key_evidence_refs": [],
                },
                {
                    "label": "BAJISTA",
                    "probability_pct": 20,
                    "rationale": "Riesgo regulatorio/geopolítico sobre exportación de chips.",
                    "key_evidence_refs": [],
                },
            ],
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
                    "content": {"parts": [{"text": json.dumps(_MOCK_GEMINI_RESPONSE)}]},
                    "finishReason": "STOP",
                }
            ]
        },
    )


def _build_clients() -> tuple[
    PolygonClient, FMPClient, TavilyClient, GeminiClient, bool
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
        return polygon, fmp, tavily, gemini, True

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
    return polygon, fmp, tavily, gemini, False


async def main() -> None:
    logging.basicConfig(level=logging.INFO)
    polygon, fmp, tavily, gemini, using_real_network = _build_clients()

    deps = build_ingestion_backed_dependencies(
        polygon,
        fmp,
        tavily,
        gemini_client=gemini,
        guardrail=_NotImplementedGuardrailAuditor(),
        notifier=_NotImplementedNotificationDispatcher(),
    )

    print(f"Usando red real: {using_real_network}\n")

    try:
        for ticker, asset_class in (
            ("NVDA", AssetClass.EQUITY),
            ("BTC-USD", AssetClass.CRYPTO),
        ):
            asset = WatchedAsset(ticker=ticker, asset_class=asset_class)
            print(f"--- {ticker} ---")

            alert = await deps.market_data.fetch_snapshot_and_detect_alert(asset)
            if alert is None:
                print("Sin alerta (variación dentro del umbral configurado).\n")
                continue

            print(
                f"Alerta detectada: severity={alert.severity.value} "
                f"trigger_value={alert.trigger_value}% requires_deep_research={alert.requires_deep_research}"
            )

            if not alert.requires_deep_research:
                print()
                continue

            dossier = await deps.deep_research.build_dossier(asset, alert)
            print(f"Dossier generado con {len(dossier.evidence)} evidencia(s).")
            print(f"Resumen: {dossier.summary}")

            projection = await deps.scenario_evaluator.evaluate(
                asset, alert, dossier, None
            )
            print(
                f"Proyección: classification={projection.classification} "
                f"(confianza={projection.classification_confidence_pct}%)"
            )
            for horizon in projection.horizons:
                labels = ", ".join(
                    f"{s.label}={s.probability_pct}%" for s in horizon.scenarios
                )
                print(
                    f"  {horizon.horizon}: {labels} "
                    f"[confianza={horizon.confidence_level}, "
                    f"completitud={horizon.data_completeness_pct}%]"
                )
            print()
    finally:
        await polygon.aclose()
        await fmp.aclose()
        await tavily.aclose()
        await gemini.aclose()


if __name__ == "__main__":
    asyncio.run(main())
