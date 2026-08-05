"""Tests de `TickerIntelligenceService` y `GET /api/v1/tickers/{ticker}/intelligence`.

Los tres contratos que este bloque promete y que son fáciles de romper sin darse cuenta:

  1. **Los tres bloques degradan por separado.** Sin Gemini se sirven los fundamentales; sin FMP se
     sirve la síntesis. Un bloque caído nunca vacía a otro.
  2. **Sin evidencia no se le pide síntesis al modelo.** Es la regla anti-alucinación central de la
     Ficha: sintetizar reportes que no se tienen es inventarlos.
  3. **El semáforo de salud financiera es determinístico**, calculado en código sobre umbrales
     explícitos — dos corridas con los mismos ratios dan el mismo veredicto.
"""

from __future__ import annotations

import asyncio
import json
from datetime import datetime, timezone
from decimal import Decimal

import httpx

from app.schemas.intelligence import (
    ConfidenceLevel,
    ConvictionLevel,
    DataAvailability,
    FinancialHealth,
    TrendDirection,
)
from app.services.ticker_intelligence_service import (
    TickerIntelligenceService,
    build_fundamentals,
)
from src.ingestion.fmp_client import FMPClient
from src.ingestion.gemini_client import GeminiClient
from src.ingestion.tavily_client import TavilyClient
from src.validation.domain_models import DataStatus, FinancialMetrics, MetricValue

_SYSTEM_PROMPT = "Sos un analista de prueba. Devolvé el JSON pedido."


# --- Helpers -------------------------------------------------------------------------------


def _metric(value: float | None, *, status: DataStatus = DataStatus.OK) -> MetricValue:
    return MetricValue(
        value=Decimal(str(value)) if value is not None else None,
        status=status if value is not None else DataStatus.NO_DISPONIBLE,
        source="test",
        as_of=datetime(2026, 8, 4, tzinfo=timezone.utc),
    )


def _metrics(
    *,
    pe: float | None = 28.0,
    peg: float | None = 1.4,
    debt_to_equity: float | None = 0.6,
    debt_to_ebitda: float | None = 1.2,
    fcf: float | None = 25_000_000_000,
    fcf_yield: float | None = 3.1,
    revenue_growth: float | None = 18.0,
    gross_margin: float | None = 0.72,
    operating_margin: float | None = 0.35,
    roe: float | None = 0.41,
    current_ratio: float | None = 3.2,
) -> FinancialMetrics:
    return FinancialMetrics(
        ticker="NVDA",
        fetched_at=datetime(2026, 8, 4, tzinfo=timezone.utc),
        price_earnings_ratio=_metric(pe),
        price_earnings_growth_ratio=_metric(peg),
        debt_to_ebitda=_metric(debt_to_ebitda),
        debt_to_equity=_metric(debt_to_equity),
        free_cash_flow=_metric(fcf),
        free_cash_flow_yield_pct=_metric(fcf_yield),
        revenue_growth_yoy_pct=_metric(revenue_growth),
        gross_margin_pct=_metric(gross_margin),
        operating_margin_pct=_metric(operating_margin),
        return_on_equity_pct=_metric(roe),
        current_ratio=_metric(current_ratio),
        shares_outstanding=_metric(24_000_000_000),
        market_cap=_metric(2_300_000_000_000),
    )


def _llm_payload(
    *,
    trend: str = "ALCISTA",
    confidence: str = "MEDIA",
    conviction: str = "ALTA",
    sources_used: list[str] | None = None,
    base_probability: float | None = 55.0,
    short_refs: list[str] | None = None,
) -> dict[str, object]:
    return {
        "rag_summary": {
            "headline": "Márgenes en expansión con guidance revisado al alza.",
            "key_points": [
                "La compañía reportó crecimiento de ingresos del 18% YoY.",
                "El margen operativo se mantiene sobre el 35%.",
            ],
            "risks": [
                "Concentración de ingresos en pocos clientes.",
                "Exposición regulatoria en mercados de exportación.",
            ],
            "sources_used": sources_used if sources_used is not None else ["NEWS-1"],
        },
        "short_term": {
            "trend": trend,
            "confidence": confidence,
            "argument": "El volumen acompaña la suba y no hay catalizador negativo a la vista.",
            "evidence_refs": short_refs if short_refs is not None else ["NEWS-1"],
        },
        "medium_term": {
            "base_case": {
                "narrative": "Sostiene márgenes y crece en línea con el guidance.",
                **(
                    {"probability_pct": base_probability}
                    if base_probability is not None
                    else {}
                ),
            },
            "bull_case": {"narrative": "Acelera por demanda de centros de datos."},
            "bear_case": {
                "narrative": "Compresión de múltiplos si sube la tasa larga."
            },
            "catalysts": ["Resultados del Q3", "Revisión de guidance anual"],
            "confidence": "MEDIA",
            "evidence_refs": ["NEWS-1"],
        },
        "long_term": {
            "thesis": "Posición dominante en aceleradores de cómputo con foso tecnológico.",
            "conviction": conviction,
            "supporting_factors": ["Escala de I+D", "Ecosistema de software"],
            "invalidation_triggers": [
                "Pérdida de share frente a un competidor con arquitectura abierta."
            ],
            "evidence_refs": ["SEC_10K-1"],
        },
    }


def _gemini_client(transport: httpx.MockTransport) -> GeminiClient:
    return GeminiClient(
        "fake-key",
        http_client=httpx.AsyncClient(
            transport=transport,
            base_url="https://generativelanguage.googleapis.com/v1beta",
        ),
    )


def _gemini_transport(
    payload: dict[str, object] | None = None,
    *,
    calls: list[httpx.Request] | None = None,
) -> httpx.MockTransport:
    body = payload if payload is not None else _llm_payload()

    def handler(request: httpx.Request) -> httpx.Response:
        if calls is not None:
            calls.append(request)
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "finishReason": "STOP",
                        "content": {
                            "parts": [{"text": json.dumps(body, ensure_ascii=False)}]
                        },
                    }
                ]
            },
        )

    return httpx.MockTransport(handler)


def _tavily_client(articles: int = 2) -> TavilyClient:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "results": [
                    {
                        "title": f"Nota {index + 1} sobre NVDA",
                        "url": f"https://news.example/{index + 1}",
                        "content": f"Contenido de la nota {index + 1}.",
                        "published_date": "2026-08-01T12:00:00Z",
                    }
                    for index in range(articles)
                ]
            },
        )

    return TavilyClient(
        "fake-key",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(handler),
            base_url="https://api.tavily.com",
        ),
    )


def _fmp_client(*, ratios: dict[str, object] | None = None) -> FMPClient:
    """Cliente de FMP contra un transporte que responde a los cinco endpoints de fundamentales más
    la búsqueda de filings.
    """

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if "sec-filings-search" in path:
            return httpx.Response(
                200,
                json=[
                    {
                        "symbol": "NVDA",
                        "formType": "10-K",
                        "filedAt": "2026-02-20T00:00:00Z",
                        "acceptedDate": "2026-02-20T16:00:00Z",
                        "link": "https://sec.example/filing",
                        "finalLink": "https://sec.example/doc",
                    }
                ],
            )
        if "ratios-ttm" in path:
            return httpx.Response(
                200,
                json=[
                    ratios
                    if ratios is not None
                    else {
                        "priceToEarningsRatio": 28.0,
                        "debtToEquityRatio": 0.6,
                        "currentRatio": 3.2,
                        "grossProfitMargin": 0.72,
                        "operatingProfitMargin": 0.35,
                        "returnOnEquity": 0.41,
                    }
                ],
            )
        if "key-metrics-ttm" in path:
            return httpx.Response(
                200,
                json=[
                    {
                        "pegRatio": 1.4,
                        "netDebtToEBITDA": 1.2,
                        "freeCashFlowYield": 0.031,
                    }
                ],
            )
        if "financial-growth" in path:
            return httpx.Response(200, json=[{"revenueGrowth": 0.18}])
        if "profile" in path:
            return httpx.Response(
                200,
                json=[
                    {
                        "marketCap": 2_300_000_000_000,
                        "sharesOutstanding": 24_000_000_000,
                    }
                ],
            )
        if "cash-flow-statement" in path:
            return httpx.Response(
                200, json=[{"freeCashFlow": 25_000_000_000, "date": "2026-06-30"}]
            )
        return httpx.Response(404, json={"error": "not found"})

    return FMPClient(
        "fake-key",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(handler),
            base_url="https://financialmodelingprep.com/stable",
        ),
    )


# --- Salud financiera (determinística, en código) -------------------------------------------


def test_financial_health_solida_with_strong_ratios() -> None:
    fundamentals = build_fundamentals(_metrics(), reason="sin datos")

    assert fundamentals.availability == DataAvailability.AVAILABLE
    assert fundamentals.financial_health == FinancialHealth.SOLIDA
    # Las notas dicen QUÉ sostiene el veredicto: un semáforo sin explicación no es auditable.
    assert fundamentals.financial_health_notes
    assert any("Deuda/Equity" in note for note in fundamentals.financial_health_notes)


def test_financial_health_debil_with_weak_ratios() -> None:
    fundamentals = build_fundamentals(
        _metrics(
            debt_to_equity=3.5,
            debt_to_ebitda=5.5,
            current_ratio=0.7,
            fcf=-1_000_000,
            operating_margin=-0.08,
        ),
        reason="sin datos",
    )

    assert fundamentals.financial_health == FinancialHealth.DEBIL


def test_financial_health_is_indeterminate_without_enough_signals() -> None:
    # Un veredicto sobre una sola señal diría más sobre lo que falta que sobre la empresa.
    fundamentals = build_fundamentals(
        _metrics(
            debt_to_equity=0.5,
            debt_to_ebitda=None,
            current_ratio=None,
            fcf=None,
            operating_margin=None,
        ),
        reason="sin datos",
    )

    assert fundamentals.financial_health == FinancialHealth.INDETERMINADA
    assert fundamentals.availability == DataAvailability.PARTIAL


def test_financial_health_is_deterministic() -> None:
    # Mismos ratios, mismo veredicto: es lo que se gana calculándolo en código y no pidiéndoselo al
    # modelo.
    metrics = _metrics()
    first = build_fundamentals(metrics, reason="sin datos")
    second = build_fundamentals(metrics, reason="sin datos")

    assert first.financial_health == second.financial_health
    assert first.financial_health_notes == second.financial_health_notes


def test_operating_margin_is_normalized_whether_fraction_or_percent() -> None:
    """FMP devuelve márgenes como fracción (0.35) o como porcentaje (35) según el endpoint. Sin
    normalizar, el umbral del 15% solo funcionaría para una de las dos formas.
    """

    as_fraction = build_fundamentals(_metrics(operating_margin=0.35), reason="x")
    as_percent = build_fundamentals(_metrics(operating_margin=35.0), reason="x")

    assert as_fraction.financial_health == as_percent.financial_health
    assert any("35.0%" in note for note in as_fraction.financial_health_notes)
    assert any("35.0%" in note for note in as_percent.financial_health_notes)


def test_ratio_with_degraded_status_is_reported_as_missing() -> None:
    # El valor de un `MetricValue` degradado no es confiable: mostrarlo sería peor que decir "no
    # disponible".
    metrics = _metrics().model_copy(
        update={"price_earnings_ratio": _metric(99.0, status=DataStatus.ERROR_API)}
    )
    fundamentals = build_fundamentals(metrics, reason="x")

    assert fundamentals.price_earnings.value is None


def test_unavailable_fundamentals_keep_every_ratio_labelled() -> None:
    # Sin métricas la Ficha igual muestra la lista completa de ratios en "no disponible", así el
    # cliente no tiene que saber qué ratios existen para dibujar la tabla.
    fundamentals = build_fundamentals(None, reason="falta FMP_API_KEY")

    assert fundamentals.availability == DataAvailability.UNAVAILABLE
    assert fundamentals.degradation_reason == "falta FMP_API_KEY"
    assert len(fundamentals.ratios) == 11
    assert all(ratio.value is None for ratio in fundamentals.ratios)
    assert all(ratio.label for ratio in fundamentals.ratios)


# --- Camino completo -----------------------------------------------------------------------


async def test_intelligence_composes_all_three_blocks() -> None:
    fmp = _fmp_client()
    tavily = _tavily_client()
    gemini = _gemini_client(_gemini_transport())
    service = TickerIntelligenceService(
        fmp_client=fmp,
        tavily_client=tavily,
        gemini_client=gemini,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        result = await service.get_intelligence("nvda", company_name="NVIDIA Corp")
    finally:
        await asyncio.gather(fmp.aclose(), tavily.aclose(), gemini.aclose())

    assert result.ticker == "NVDA"  # normalizado a mayúsculas
    assert result.company_name == "NVIDIA Corp"
    assert result.is_fully_available is True

    assert result.fundamentals.availability == DataAvailability.AVAILABLE
    assert result.fundamentals.price_earnings.value == 28.0
    assert result.fundamentals.debt_to_equity.value == 0.6

    assert result.rag_summary.availability == DataAvailability.AVAILABLE
    assert result.rag_summary.headline is not None
    assert len(result.rag_summary.key_points) == 2
    assert len(result.rag_summary.risks) == 2
    assert result.rag_summary.sources

    projections = result.projections
    assert projections.availability == DataAvailability.AVAILABLE
    assert projections.short_term is not None
    assert projections.short_term.trend == TrendDirection.ALCISTA
    assert projections.short_term.confidence == ConfidenceLevel.MEDIA
    assert projections.medium_term is not None
    assert projections.medium_term.base_case.label == "BASE"
    assert projections.medium_term.base_case.probability_pct == 55.0
    assert projections.medium_term.bull_case.label == "ALCISTA"
    assert projections.medium_term.bear_case.label == "BAJISTA"
    assert projections.medium_term.catalysts
    assert projections.long_term is not None
    assert projections.long_term.conviction == ConvictionLevel.ALTA
    # Obligatorio por contrato: una tesis sin condiciones de invalidación no es una tesis.
    assert projections.long_term.invalidation_triggers


async def test_evidence_and_fundamentals_reach_the_prompt() -> None:
    """El prompt exige que el modelo se apoye SOLO en los bloques de contexto. Acá se verifica el
    otro lado del contrato: que esos bloques efectivamente contengan los datos.
    """

    calls: list[httpx.Request] = []
    fmp = _fmp_client()
    tavily = _tavily_client()
    gemini = _gemini_client(_gemini_transport(calls=calls))
    service = TickerIntelligenceService(
        fmp_client=fmp,
        tavily_client=tavily,
        gemini_client=gemini,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        await service.get_intelligence("NVDA")
    finally:
        await asyncio.gather(fmp.aclose(), tavily.aclose(), gemini.aclose())

    assert len(calls) == 1
    sent = calls[0].content.decode()
    assert "<fundamentals>" in sent
    assert "<evidence>" in sent
    assert "P/E" in sent
    assert "Deuda/Equity" in sent
    # El veredicto calculado viaja al prompt para que el modelo razone sobre él en vez de recalcularlo.
    assert "Salud financiera calculada" in sent


async def test_missing_ratios_are_declared_not_omitted_in_the_prompt() -> None:
    # Si el bloque omitiera los ratios ausentes, el modelo no tendría forma de saber que faltan y
    # podría estimarlos — justo lo que la regla de cero alucinación prohíbe.
    calls: list[httpx.Request] = []
    tavily = _tavily_client()
    gemini = _gemini_client(_gemini_transport(calls=calls))
    service = TickerIntelligenceService(
        tavily_client=tavily, gemini_client=gemini, system_prompt=_SYSTEM_PROMPT
    )

    try:
        await service.get_intelligence("NVDA")
    finally:
        await asyncio.gather(tavily.aclose(), gemini.aclose())

    sent = calls[0].content.decode()
    assert "no disponible" in sent


# --- Trazabilidad de fuentes ---------------------------------------------------------------


async def test_hallucinated_source_refs_are_dropped() -> None:
    """Una cita a una fuente que no está en el corpus es una alucinación con formato de rigor. Se
    descarta en vez de mostrarle al usuario una fuente inventada.
    """

    tavily = _tavily_client(articles=1)
    gemini = _gemini_client(
        _gemini_transport(
            _llm_payload(
                sources_used=["NEWS-99", "INVENTADO-1"],
                short_refs=["NEWS-1", "NO-EXISTE"],
            )
        )
    )
    service = TickerIntelligenceService(
        tavily_client=tavily, gemini_client=gemini, system_prompt=_SYSTEM_PROMPT
    )

    try:
        result = await service.get_intelligence("NVDA")
    finally:
        await asyncio.gather(tavily.aclose(), gemini.aclose())

    assert result.projections.short_term is not None
    # Solo sobrevive la ref que existe de verdad.
    assert result.projections.short_term.evidence_refs == ["NEWS-1"]
    # Ninguna de las "fuentes usadas" era válida, así que se listan las reales del corpus.
    assert [source.ref_id for source in result.rag_summary.sources] == ["NEWS-1"]


async def test_out_of_range_probability_is_discarded_not_clamped() -> None:
    # Una probabilidad de 150% es un dato roto, no algo a recortar a 100: el escenario queda sin
    # número, que el schema permite explícitamente.
    tavily = _tavily_client()
    gemini = _gemini_client(_gemini_transport(_llm_payload(base_probability=150.0)))
    service = TickerIntelligenceService(
        tavily_client=tavily, gemini_client=gemini, system_prompt=_SYSTEM_PROMPT
    )

    try:
        result = await service.get_intelligence("NVDA")
    finally:
        await asyncio.gather(tavily.aclose(), gemini.aclose())

    assert result.projections.medium_term is not None
    assert result.projections.medium_term.base_case.probability_pct is None


async def test_unexpected_enum_value_falls_back_to_the_conservative_option() -> None:
    """El `response_schema` declara los enums, pero no se confía en que el proveedor los respete: un
    valor libre llegaría hasta la UI. El fallback degrada la afirmación en vez de fortalecerla.
    """

    tavily = _tavily_client()
    gemini = _gemini_client(
        _gemini_transport(
            _llm_payload(trend="EUFÓRICO", confidence="TOTAL", conviction="ABSOLUTA")
        )
    )
    service = TickerIntelligenceService(
        tavily_client=tavily, gemini_client=gemini, system_prompt=_SYSTEM_PROMPT
    )

    try:
        result = await service.get_intelligence("NVDA")
    finally:
        await asyncio.gather(tavily.aclose(), gemini.aclose())

    assert result.projections.short_term is not None
    assert result.projections.short_term.trend == TrendDirection.LATERAL
    assert result.projections.short_term.confidence == ConfidenceLevel.BAJA
    assert result.projections.long_term is not None
    assert result.projections.long_term.conviction == ConvictionLevel.BAJA


# --- Degradaciones independientes -----------------------------------------------------------


async def test_without_gemini_fundamentals_still_served() -> None:
    fmp = _fmp_client()
    service = TickerIntelligenceService(
        fmp_client=fmp, gemini_client=None, system_prompt=_SYSTEM_PROMPT
    )

    try:
        result = await service.get_intelligence("NVDA")
    finally:
        await fmp.aclose()

    # El bloque caro cae, el barato sobrevive: los ratios y el semáforo siguen ahí.
    assert result.fundamentals.availability == DataAvailability.AVAILABLE
    assert result.fundamentals.financial_health != FinancialHealth.INDETERMINADA
    assert result.rag_summary.availability == DataAvailability.UNAVAILABLE
    assert result.projections.availability == DataAvailability.UNAVAILABLE
    assert result.rag_summary.degradation_reason is not None
    assert "GEMINI_API_KEY" in result.rag_summary.degradation_reason
    assert result.is_fully_available is False


async def test_without_fmp_synthesis_still_served() -> None:
    # La simétrica de la anterior: sin fundamentales, la síntesis sobre noticias sigue viniendo.
    tavily = _tavily_client()
    gemini = _gemini_client(_gemini_transport())
    service = TickerIntelligenceService(
        tavily_client=tavily, gemini_client=gemini, system_prompt=_SYSTEM_PROMPT
    )

    try:
        result = await service.get_intelligence("NVDA")
    finally:
        await asyncio.gather(tavily.aclose(), gemini.aclose())

    assert result.fundamentals.availability == DataAvailability.UNAVAILABLE
    assert result.fundamentals.degradation_reason is not None
    assert "FMP_API_KEY" in result.fundamentals.degradation_reason
    assert result.rag_summary.availability == DataAvailability.AVAILABLE
    assert result.projections.availability == DataAvailability.AVAILABLE


async def test_without_evidence_the_model_is_not_called() -> None:
    """La regla anti-alucinación central: pedirle a un modelo que sintetice reportes que no tiene es
    pedirle que los invente, y esta Ficha es donde eso costaría más caro.
    """

    calls: list[httpx.Request] = []
    gemini = _gemini_client(_gemini_transport(calls=calls))
    # Sin Tavily ni FMP no hay corpus posible.
    service = TickerIntelligenceService(
        gemini_client=gemini, system_prompt=_SYSTEM_PROMPT
    )

    try:
        result = await service.get_intelligence("NVDA")
    finally:
        await gemini.aclose()

    assert calls == []
    assert result.rag_summary.availability == DataAvailability.UNAVAILABLE
    assert result.projections.availability == DataAvailability.UNAVAILABLE
    assert result.projections.degradation_reason is not None
    assert "inventarlas" in result.projections.degradation_reason


async def test_empty_news_result_also_skips_the_model() -> None:
    # Tavily configurado pero sin resultados es el mismo caso: no hay material que sintetizar.
    calls: list[httpx.Request] = []
    tavily = _tavily_client(articles=0)
    gemini = _gemini_client(_gemini_transport(calls=calls))
    service = TickerIntelligenceService(
        tavily_client=tavily, gemini_client=gemini, system_prompt=_SYSTEM_PROMPT
    )

    try:
        result = await service.get_intelligence("NVDA")
    finally:
        await asyncio.gather(tavily.aclose(), gemini.aclose())

    assert calls == []
    assert result.rag_summary.availability == DataAvailability.UNAVAILABLE


async def test_degrades_when_gemini_call_fails() -> None:
    def failing(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, json={"error": "boom"})

    fmp = _fmp_client()
    tavily = _tavily_client()
    gemini = _gemini_client(httpx.MockTransport(failing))
    service = TickerIntelligenceService(
        fmp_client=fmp,
        tavily_client=tavily,
        gemini_client=gemini,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        result = await service.get_intelligence("NVDA")
    finally:
        await asyncio.gather(fmp.aclose(), tavily.aclose(), gemini.aclose())

    assert result.fundamentals.availability == DataAvailability.AVAILABLE
    assert result.rag_summary.availability == DataAvailability.UNAVAILABLE
    assert result.projections.availability == DataAvailability.UNAVAILABLE


async def test_degrades_when_model_output_is_not_json() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "finishReason": "STOP",
                        "content": {"parts": [{"text": "esto no es JSON"}]},
                    }
                ]
            },
        )

    tavily = _tavily_client()
    gemini = _gemini_client(httpx.MockTransport(handler))
    service = TickerIntelligenceService(
        tavily_client=tavily, gemini_client=gemini, system_prompt=_SYSTEM_PROMPT
    )

    try:
        result = await service.get_intelligence("NVDA")
    finally:
        await asyncio.gather(tavily.aclose(), gemini.aclose())

    assert result.rag_summary.availability == DataAvailability.UNAVAILABLE
    assert result.rag_summary.degradation_reason is not None
    assert "no se pudo interpretar" in result.rag_summary.degradation_reason


async def test_degrades_when_model_output_is_missing_a_required_block() -> None:
    # Una Ficha a la que le falta un horizonte no es una Ficha parcial: es una respuesta que no
    # cumple el contrato, y se trata como fallo del modelo.
    payload = _llm_payload()
    del payload["long_term"]

    tavily = _tavily_client()
    gemini = _gemini_client(_gemini_transport(payload))
    service = TickerIntelligenceService(
        tavily_client=tavily, gemini_client=gemini, system_prompt=_SYSTEM_PROMPT
    )

    try:
        result = await service.get_intelligence("NVDA")
    finally:
        await asyncio.gather(tavily.aclose(), gemini.aclose())

    assert result.projections.availability == DataAvailability.UNAVAILABLE


# --- Caché ---------------------------------------------------------------------------------


async def test_intelligence_is_cached_per_ticker() -> None:
    calls: list[httpx.Request] = []
    tavily = _tavily_client()
    gemini = _gemini_client(_gemini_transport(calls=calls))
    service = TickerIntelligenceService(
        tavily_client=tavily,
        gemini_client=gemini,
        cache_ttl_seconds=600.0,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        first = await service.get_intelligence("NVDA")
        second = await service.get_intelligence("NVDA")
        # Otro ticker NO comparte caché: es otra Ficha.
        await service.get_intelligence("AAPL")
    finally:
        await asyncio.gather(tavily.aclose(), gemini.aclose())

    assert len(calls) == 2
    assert first.served_from_cache is False
    assert second.served_from_cache is True
    assert second.rag_summary.headline == first.rag_summary.headline


async def test_force_refresh_bypasses_the_cache() -> None:
    calls: list[httpx.Request] = []
    tavily = _tavily_client()
    gemini = _gemini_client(_gemini_transport(calls=calls))
    service = TickerIntelligenceService(
        tavily_client=tavily,
        gemini_client=gemini,
        cache_ttl_seconds=600.0,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        await service.get_intelligence("NVDA")
        refreshed = await service.get_intelligence("NVDA", force_refresh=True)
    finally:
        await asyncio.gather(tavily.aclose(), gemini.aclose())

    assert len(calls) == 2
    assert refreshed.served_from_cache is False


async def test_cache_expires_after_ttl() -> None:
    calls: list[httpx.Request] = []
    tavily = _tavily_client()
    gemini = _gemini_client(_gemini_transport(calls=calls))
    # TTL en cero: cualquier tiempo transcurrido la vence, sin dormir el test.
    service = TickerIntelligenceService(
        tavily_client=tavily,
        gemini_client=gemini,
        cache_ttl_seconds=0.0,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        await service.get_intelligence("NVDA")
        await service.get_intelligence("NVDA")
    finally:
        await asyncio.gather(tavily.aclose(), gemini.aclose())

    assert len(calls) == 2


async def test_concurrent_requests_for_the_same_ticker_share_one_model_call() -> None:
    """Sin el lock por ticker, N usuarios abriendo la misma Ficha a la vez disparan N llamadas al
    LLM — justo el gasto que la caché existe para evitar.
    """

    calls: list[httpx.Request] = []
    tavily = _tavily_client()
    gemini = _gemini_client(_gemini_transport(calls=calls))
    service = TickerIntelligenceService(
        tavily_client=tavily,
        gemini_client=gemini,
        cache_ttl_seconds=600.0,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        results = await asyncio.gather(
            *(service.get_intelligence("NVDA") for _ in range(5))
        )
    finally:
        await asyncio.gather(tavily.aclose(), gemini.aclose())

    assert len(calls) == 1
    assert all(result.ticker == "NVDA" for result in results)


async def test_different_tickers_do_not_block_each_other() -> None:
    # El lock es POR ticker: dos fichas distintas se compilan en paralelo, no en fila.
    calls: list[httpx.Request] = []
    tavily = _tavily_client()
    gemini = _gemini_client(_gemini_transport(calls=calls))
    service = TickerIntelligenceService(
        tavily_client=tavily,
        gemini_client=gemini,
        cache_ttl_seconds=600.0,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        await asyncio.gather(
            service.get_intelligence("NVDA"),
            service.get_intelligence("AAPL"),
            service.get_intelligence("MSFT"),
        )
    finally:
        await asyncio.gather(tavily.aclose(), gemini.aclose())

    assert len(calls) == 3


# --- Endpoint ------------------------------------------------------------------------------


async def _auth_headers(client: httpx.AsyncClient, email: str) -> dict[str, str]:
    await client.post(
        "/api/v1/auth/register",
        json={"email": email, "password": "supersecreta1"},
    )
    login = await client.post(
        "/api/v1/auth/login",
        json={"email": email, "password": "supersecreta1"},
    )
    return {"Authorization": f"Bearer {login.json()['access_token']}"}


async def test_intelligence_endpoint_requires_auth(client: httpx.AsyncClient) -> None:
    response = await client.get("/api/v1/tickers/NVDA/intelligence")
    assert response.status_code == 401


async def test_intelligence_endpoint_returns_a_valid_shape_without_credentials(
    client: httpx.AsyncClient,
) -> None:
    """El contrato central del endpoint: sin credenciales devuelve 200 con la Ficha completa en
    forma y explícitamente vacía en contenido. Un 503 obligaría al cliente a traducirlo a mano.
    """

    headers = await _auth_headers(client, "intel-empty@example.com")
    response = await client.get("/api/v1/tickers/NVDA/intelligence", headers=headers)

    assert response.status_code == 200
    body = response.json()
    assert body["ticker"] == "NVDA"
    for block in ("fundamentals", "rag_summary", "projections"):
        assert body[block]["availability"] == "UNAVAILABLE"
        assert body[block]["degradation_reason"] is not None
    # La tabla de ratios llega completa aunque esté vacía, así el cliente puede dibujarla.
    assert body["fundamentals"]["price_earnings"]["label"] == "P/E"
    assert body["fundamentals"]["debt_to_equity"]["value"] is None
    assert body["fundamentals"]["financial_health"] == "INDETERMINADA"


async def test_intelligence_endpoint_serves_a_configured_service(
    client: httpx.AsyncClient,
) -> None:
    from app.main import app

    fmp = _fmp_client()
    tavily = _tavily_client()
    gemini = _gemini_client(_gemini_transport())
    app.state.ticker_intelligence_service = TickerIntelligenceService(
        fmp_client=fmp,
        tavily_client=tavily,
        gemini_client=gemini,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        headers = await _auth_headers(client, "intel-ok@example.com")
        response = await client.get(
            "/api/v1/tickers/NVDA/intelligence", headers=headers
        )
    finally:
        await asyncio.gather(fmp.aclose(), tavily.aclose(), gemini.aclose())

    assert response.status_code == 200
    body = response.json()
    assert body["fundamentals"]["availability"] == "AVAILABLE"
    assert body["fundamentals"]["financial_health"] == "SOLIDA"
    assert body["rag_summary"]["availability"] == "AVAILABLE"
    assert body["projections"]["short_term"]["trend"] == "ALCISTA"
    assert body["projections"]["medium_term"]["base_case"]["label"] == "BASE"
    assert body["projections"]["long_term"]["invalidation_triggers"]


async def test_intelligence_endpoint_enriches_the_company_name_from_the_catalog(
    client: httpx.AsyncClient,
    db_session_factory: object,
) -> None:
    from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

    from app.models.enums import ExchangeType
    from app.models.ticker import Ticker

    assert isinstance(db_session_factory, async_sessionmaker)
    factory: async_sessionmaker[AsyncSession] = db_session_factory
    async with factory() as session:
        session.add(
            Ticker(
                symbol="NVDA",
                name="NVIDIA Corporation",
                primary_exchange="XNAS",
                exchange=ExchangeType.NASDAQ,
                asset_type="CS",
                active=True,
            )
        )
        await session.commit()

    headers = await _auth_headers(client, "intel-name@example.com")
    response = await client.get("/api/v1/tickers/NVDA/intelligence", headers=headers)

    assert response.status_code == 200
    assert response.json()["company_name"] == "NVIDIA Corporation"


async def test_intelligence_endpoint_works_for_a_ticker_outside_the_catalog(
    client: httpx.AsyncClient,
) -> None:
    # Una cripto o un listado reciente no están en el catálogo de acciones, pero igual tienen
    # fundamentales y noticias: el endpoint no debe rechazarlos.
    headers = await _auth_headers(client, "intel-unknown@example.com")
    response = await client.get("/api/v1/tickers/BTC-USD/intelligence", headers=headers)

    assert response.status_code == 200
    body = response.json()
    assert body["ticker"] == "BTC-USD"
    assert body["company_name"] is None
