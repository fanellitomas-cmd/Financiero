"""Prueba End-to-End del pipeline completo de LangGraph (Nodo 1 Ingesta -> Nodo 2 Investigador
-> Nodo 3 Evaluador de Escenarios -> Nodo 4 Guardrail -> Nodo 5 Notificador nativo) para UN
ticker pasado por parámetro.

CÓMO PROBARLO EN LA TERMINAL
----------------------------
1) Con credenciales reales: copiá `.env.example` a `.env`, completá las API keys
   (POLYGON_API_KEY, FMP_API_KEY, TAVILY_API_KEY, GEMINI_API_KEY) y corré:

       python -m scripts.test_e2e NVDA
       python -m scripts.test_e2e BTC --asset-class crypto

   El script entonces captura un evento de mercado REAL (el snapshot de precio vigente en
   Polygon) y corre todo el pipeline sobre él. Si la variación del día no supera el umbral
   configurado, no habrá alerta — eso es correcto y esperable en un E2E real, no un fallo del
   script.

2) Sin credenciales (o para CI / este sandbox sin acceso de red a los proveedores): no hace
   falta ningún `.env`. El script detecta la ausencia de API keys y SIMULA el evento de
   mercado con un `httpx.MockTransport` determinístico que fuerza una variación grande, para
   poder demostrar el pipeline completo (incluyendo Nodo 2/3/4) sin depender de que el mercado
   real esté moviéndose ese día.

Argumentos:
    ticker          Símbolo a analizar, ej. NVDA o BTC (posicional, obligatorio)
    --asset-class   stock | crypto (default: stock)
    --profile       technical | beginner — perfil de usuario, define default_view del
                    payload de push (default: technical)

Ejemplos:
    python -m scripts.test_e2e NVDA
    python -m scripts.test_e2e AAPL --profile beginner
    python -m scripts.test_e2e BTC --asset-class crypto --profile beginner
"""

from __future__ import annotations

import argparse
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


# --------------------------------------------------------------------------------
# Handlers de simulación — solo se usan si faltan credenciales reales. Fuerzan una
# variación de precio grande (8.72%) para garantizar que el pipeline completo (Nodo
# 2/3/4/5) se ejercite sin depender de que el mercado real se mueva ese día.
# --------------------------------------------------------------------------------
def _simulated_polygon_handler(request: httpx.Request) -> httpx.Response:
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


def _simulated_fmp_handler(request: httpx.Request) -> httpx.Response:
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
    return httpx.Response(404, json={"error": "no usado en esta simulación"})


def _simulated_tavily_handler(request: httpx.Request) -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "results": [
                {
                    "title": "Movimiento notable reportado en la nota de prensa",
                    "url": "https://example.com/news/1",
                    "content": (
                        "El activo tuvo un movimiento notable impulsado por catalizadores "
                        "recientes del sector. " * 5
                    ),
                    "published_date": "2026-07-30T09:00:00Z",
                }
            ]
        },
    )


def _simulated_gemini_response() -> dict[str, object]:
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


def _simulated_gemini_handler(request: httpx.Request) -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "candidates": [
                {
                    "content": {
                        "parts": [{"text": json.dumps(_simulated_gemini_response())}]
                    },
                    "finishReason": "STOP",
                }
            ]
        },
    )


def _simulated_internal_backend_handler(request: httpx.Request) -> httpx.Response:
    return httpx.Response(200, json={"alert_id": "db-e2e-simulated"})


def _build_clients() -> tuple[
    PolygonClient, FMPClient, TavilyClient, GeminiClient, InternalBackendClient, bool
]:
    """Devuelve los 5 clientes + un flag indicando si se está usando red real o simulada."""

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
        "credenciales_reales_ausentes_usando_simulacion",
        extra={
            "hint": (
                "definí POLYGON_API_KEY/FMP_API_KEY/TAVILY_API_KEY/GEMINI_API_KEY en .env "
                "(ver .env.example) para capturar un evento de mercado real"
            )
        },
    )
    polygon = PolygonClient(
        "simulated-key",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(_simulated_polygon_handler),
            base_url="https://api.polygon.io",
        ),
    )
    fmp = FMPClient(
        "simulated-key",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(_simulated_fmp_handler),
            base_url="https://financialmodelingprep.com/stable",
        ),
    )
    tavily = TavilyClient(
        "simulated-key",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(_simulated_tavily_handler),
            base_url="https://api.tavily.com",
        ),
    )
    gemini = GeminiClient(
        "simulated-key",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(_simulated_gemini_handler),
            base_url="https://generativelanguage.googleapis.com/v1beta",
        ),
    )
    backend = InternalBackendClient(
        "https://backend.internal.simulated",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(_simulated_internal_backend_handler),
            base_url="https://backend.internal.simulated",
        ),
    )
    return polygon, fmp, tavily, gemini, backend, False


def _normalize_ticker(ticker: str, asset_class: AssetClass) -> str:
    """Para cripto, Polygon espera un par (ej. BTC-USD) — si el usuario solo pasó 'BTC',
    se completa con '-USD' para que el snapshot tenga sentido.
    """

    if asset_class == AssetClass.CRYPTO and "-" not in ticker:
        return f"{ticker.upper()}-USD"
    return ticker.upper()


def _print_section(title: str) -> None:
    print(f"\n{'=' * 78}\n {title}\n{'=' * 78}")


async def run_e2e(
    ticker: str, asset_class: AssetClass, user_profile: UserProfile
) -> None:
    polygon, fmp, tavily, gemini, backend, using_real_network = _build_clients()

    deps = build_ingestion_backed_dependencies(
        polygon, fmp, tavily, gemini_client=gemini, internal_backend_client=backend
    )
    graph = build_graph(deps)

    normalized_ticker = _normalize_ticker(ticker, asset_class)
    asset = WatchedAsset(ticker=normalized_ticker, asset_class=asset_class)

    print(f"Ticker: {normalized_ticker} ({asset_class.value})")
    print(f"Perfil: {user_profile.value}")
    print(f"Usando red real: {using_real_network}")

    try:
        # --- Inyección de dependencias + ejecución del grafo completo -------------------
        final_state = await graph.ainvoke(
            AgentState(watched_asset=asset, user_profile=user_profile)
        )

        # --- 1) Estado final del agente --------------------------------------------------
        _print_section("ESTADO FINAL DEL AGENTE")
        alert = final_state.get("market_alert")
        if alert is None:
            print(
                "market_alert: ninguna (variación dentro de los umbrales configurados)."
            )
            print(
                "\nNo se generó ninguna alerta para este ticker en este momento — fin del E2E."
            )
            return

        print(
            f"market_alert: severity={alert.severity.value} "
            f"trigger_value={alert.trigger_value}% requires_deep_research={alert.requires_deep_research}"
        )

        dossier = final_state.get("research_dossier")
        if dossier is not None:
            print(
                f"research_dossier: {len(dossier.evidence)} evidencia(s) — {dossier.summary}"
            )
        else:
            print(
                "research_dossier: no se ejecutó (severity LOW, sin investigación profunda)."
            )

        projection = final_state.get("asset_projection")
        if projection is not None:
            print(
                f"asset_projection: classification={projection.classification} "
                f"({projection.classification_confidence_pct}% confianza), "
                f"{len(projection.horizons)} horizonte(s)"
            )

        print(f"guardrail_retry_count: {final_state.get('guardrail_retry_count', 0)}")

        # --- 2) Reporte de validación del Guardrail --------------------------------------
        _print_section("REPORTE DE VALIDACIÓN DEL GUARDRAIL")
        guardrail_result = final_state.get("guardrail_result")
        if guardrail_result is None:
            print("No se ejecutó el Guardrail (no hubo AssetProjection que auditar).")
        else:
            print(f"is_valid:            {guardrail_result.is_valid}")
            print(f"hallucination_score: {guardrail_result.hallucination_score:.2f}")
            print(f"recommended_action:  {guardrail_result.recommended_action.value}")
            if guardrail_result.flagged_issues:
                print("flagged_issues:")
                for issue in guardrail_result.flagged_issues:
                    print(f"  - {issue}")
            else:
                print("flagged_issues:      (ninguno)")

        # --- 3) Payload JSON estructurado para la notificación Push ----------------------
        _print_section("PAYLOAD JSON PARA NOTIFICACIÓN PUSH")
        notification_payload = final_state.get("notification_payload")
        if notification_payload is None:
            print("No se generó payload de notificación.")
        else:
            print(notification_payload.model_dump_json(indent=2))
            print(
                f"\npush_dispatched={notification_payload.push_dispatched} "
                f"alert_db_id={notification_payload.alert_db_id}"
            )
    finally:
        await polygon.aclose()
        await fmp.aclose()
        await tavily.aclose()
        await gemini.aclose()
        await backend.aclose()


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Prueba End-to-End del pipeline de 5 nodos (Ingesta -> Notificación Push)."
    )
    parser.add_argument("ticker", help="Símbolo a analizar, ej. NVDA o BTC")
    parser.add_argument(
        "--asset-class",
        choices=["stock", "crypto"],
        default="stock",
        help="Tipo de activo (default: stock)",
    )
    parser.add_argument(
        "--profile",
        choices=["technical", "beginner"],
        default="technical",
        help="Perfil de usuario; define default_view del payload de push (default: technical)",
    )
    return parser.parse_args()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)

    cli_args = _parse_args()
    cli_asset_class = (
        AssetClass.CRYPTO if cli_args.asset_class == "crypto" else AssetClass.EQUITY
    )
    cli_user_profile = (
        UserProfile.TRADUCTOR_FINANCIERO
        if cli_args.profile == "beginner"
        else UserProfile.FICHA_INTELIGENCIA_PROFUNDA
    )

    asyncio.run(run_e2e(cli_args.ticker, cli_asset_class, cli_user_profile))
