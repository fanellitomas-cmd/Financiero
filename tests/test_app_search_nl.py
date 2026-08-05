"""Tests de `TickerSearchService` y `POST /api/v1/tickers/search-nl`.

Los contratos que este bloque promete y que son fáciles de romper sin darse cuenta:

  1. **El modelo interpreta, el código filtra.** Los símbolos salen del catálogo y los ratios del
     proveedor — nunca de lo que el LLM "recuerde". Un candidato cuyo ratio no se pudo medir NO
     entra: no se puede afirmar que cumple algo que nadie midió.
  2. **`match_reason` se compone en código** a partir de los valores medidos, así que dice la
     verdad por construcción.
  3. **Cada degradación se declara.** Sin Gemini se busca por texto y se dice; sin FMP los filtros
     numéricos no se aplican y viajan en `unapplied_criteria`, porque una lista filtrada solo por
     sector presentada como si cumpliera "P/E menor a 20" sería una respuesta falsa.
  4. **La salida del modelo se re-valida**: rangos invertidos, sectores inventados y valores no
     finitos no llegan al filtro.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from decimal import Decimal

import httpx
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.enums import ExchangeType
from app.models.ticker import Ticker
from app.schemas.portfolio_audit import PortfolioSector
from app.schemas.search import CriteriaSource, NumericRange
from app.services.ticker_search_service import (
    TickerSearchService,
    _LLMSearchCriteria,
    build_criteria,
)
from src.ingestion.fmp_client import FMPClient
from src.ingestion.gemini_client import GeminiClient
from src.validation.domain_models import DataStatus, FinancialMetrics, MetricValue

_SYSTEM_PROMPT = "Sos un traductor de consultas de prueba. Devolvé el JSON pedido."


# --- Dobles ---------------------------------------------------------------------------------


def _gemini_client(transport: httpx.MockTransport) -> GeminiClient:
    """Cliente real contra un transporte falso, igual que en el resto de la suite: así el parseo de
    la respuesta del proveedor también queda ejercitado.
    """

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
    raw_text: str | None = None,
    status_code: int = 200,
    calls: list[httpx.Request] | None = None,
) -> httpx.MockTransport:
    def handler(request: httpx.Request) -> httpx.Response:
        if calls is not None:
            calls.append(request)
        if status_code != 200:
            return httpx.Response(status_code, json={"error": "boom"})
        text = raw_text if raw_text is not None else json.dumps(payload or {})
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "finishReason": "STOP",
                        "content": {"parts": [{"text": text}]},
                    }
                ]
            },
        )

    return httpx.MockTransport(handler)


def _metric(value: float | None) -> MetricValue:
    return MetricValue(
        value=Decimal(str(value)) if value is not None else None,
        status=DataStatus.OK if value is not None else DataStatus.NO_DISPONIBLE,
        source="test",
        as_of=datetime(2026, 8, 5, tzinfo=timezone.utc),
    )


def _metrics(
    ticker: str,
    *,
    pe: float | None = 20.0,
    debt_to_equity: float | None = 0.4,
    roe: float | None = 0.25,
    revenue_growth: float | None = 0.18,
    market_cap: float | None = 500_000_000_000,
    free_cash_flow: float | None = 10_000_000_000,
) -> FinancialMetrics:
    return FinancialMetrics(
        ticker=ticker,
        fetched_at=datetime(2026, 8, 5, tzinfo=timezone.utc),
        price_earnings_ratio=_metric(pe),
        price_earnings_growth_ratio=_metric(1.2),
        debt_to_ebitda=_metric(1.0),
        debt_to_equity=_metric(debt_to_equity),
        free_cash_flow=_metric(free_cash_flow),
        free_cash_flow_yield_pct=_metric(3.0),
        revenue_growth_yoy_pct=_metric(revenue_growth),
        gross_margin_pct=_metric(0.6),
        operating_margin_pct=_metric(0.3),
        return_on_equity_pct=_metric(roe),
        current_ratio=_metric(2.0),
        shares_outstanding=_metric(1_000_000_000),
        market_cap=_metric(market_cap),
    )


class _FakeFMP(FMPClient):
    """Métricas fijas por símbolo. Se hereda de `FMPClient` sin llamar a `super().__init__`: no
    hace falta cliente HTTP porque ningún método que pegue a la red se ejecuta.
    """

    def __init__(self, by_symbol: dict[str, FinancialMetrics]) -> None:
        self._by_symbol = by_symbol
        self.calls: list[str] = []

    async def get_financial_metrics(self, ticker: str) -> FinancialMetrics:
        self.calls.append(ticker)
        return self._by_symbol.get(ticker) or _metrics(ticker, pe=None)


async def _seed_catalog(
    session_factory: async_sessionmaker[AsyncSession],
    rows: list[tuple[str, str, ExchangeType, str | None]],
) -> None:
    async with session_factory() as session:
        for symbol, name, exchange, sector in rows:
            session.add(
                Ticker(
                    symbol=symbol,
                    name=name,
                    exchange=exchange,
                    sector=sector,
                    active=True,
                )
            )
        await session.commit()


_TECH_CATALOG: list[tuple[str, str, ExchangeType, str | None]] = [
    ("NVDA", "NVIDIA Corporation", ExchangeType.NASDAQ, "Technology"),
    ("AAPL", "Apple Inc.", ExchangeType.NASDAQ, "Technology"),
    ("MSFT", "Microsoft Corporation", ExchangeType.NASDAQ, "Technology"),
    ("JPM", "JPMorgan Chase & Co.", ExchangeType.NYSE, "Financial Services"),
    ("KO", "Coca-Cola Company", ExchangeType.NYSE, "Consumer Defensive"),
]


# --- Normalización de la salida del modelo --------------------------------------------------


def test_criteria_from_model_output() -> None:
    criteria = build_criteria(
        _LLMSearchCriteria(
            interpretation="Buscás tecnológicas baratas.",
            sectors=["TECNOLOGIA"],
            exchanges=["NASDAQ"],
            price_earnings_max=15.0,
            debt_to_equity_max=0.5,
            free_cash_flow_positive=True,
        )
    )

    assert criteria.sectors == [PortfolioSector.TECNOLOGIA]
    assert criteria.exchanges == [ExchangeType.NASDAQ]
    assert criteria.price_earnings == NumericRange(minimum=None, maximum=15.0)
    assert criteria.requires_metrics is True
    assert criteria.is_empty is False


def test_inverted_range_is_corrected_not_rejected() -> None:
    """Un rango dado vuelta es un error de interpretación del modelo, no una búsqueda imposible:
    devolver cero resultados sin explicación sería peor que corregirlo.
    """

    criteria = build_criteria(
        _LLMSearchCriteria(price_earnings_min=30.0, price_earnings_max=10.0)
    )

    assert criteria.price_earnings.minimum == 10.0
    assert criteria.price_earnings.maximum == 30.0


def test_non_finite_values_are_discarded() -> None:
    """Un infinito comparado con `<`/`>` deja pasar todo o filtra todo, sin que nada falle. Se
    descarta el criterio en vez de aplicar uno sin sentido.
    """

    criteria = build_criteria(
        _LLMSearchCriteria(
            price_earnings_max=float("inf"),
            debt_to_equity_min=float("nan"),
        )
    )

    assert criteria.price_earnings.is_empty
    assert criteria.debt_to_equity.is_empty


def test_unknown_sector_is_dropped_and_provider_vocabulary_accepted() -> None:
    criteria = build_criteria(
        _LLMSearchCriteria(sectors=["BIOTECNOLOGIA_CUANTICA", "Technology", "SALUD"])
    )

    # El inventado se descarta; el del vocabulario del proveedor se reconoce igual.
    assert criteria.sectors == [PortfolioSector.TECNOLOGIA, PortfolioSector.SALUD]


def test_unknown_and_other_exchange_are_dropped() -> None:
    # `OTHER` es el cajón de las bolsas que el producto no ofrece: como filtro no significa nada
    # que el usuario haya podido pedir.
    criteria = build_criteria(
        _LLMSearchCriteria(exchanges=["NASDAQ", "OTHER", "BOLSA_LUNAR"])
    )

    assert criteria.exchanges == [ExchangeType.NASDAQ]


def test_criteria_without_anything_recognizable_is_empty() -> None:
    criteria = build_criteria(
        _LLMSearchCriteria(interpretation="No entendí la consulta.")
    )

    assert criteria.is_empty is True
    assert criteria.requires_metrics is False


# --- Búsqueda: filtros locales ---------------------------------------------------------------


async def test_filters_catalog_by_sector_and_exchange(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(db_session_factory, _TECH_CATALOG)
    service = TickerSearchService(
        db_session_factory,
        gemini_client=_gemini_client(
            _gemini_transport(
                {
                    "interpretation": "Buscás tecnológicas de Nasdaq.",
                    "sectors": ["TECNOLOGIA"],
                    "exchanges": ["NASDAQ"],
                }
            )
        ),
        system_prompt=_SYSTEM_PROMPT,
    )

    response = await service.search("tecnológicas de nasdaq")

    assert response.criteria_source == CriteriaSource.AI
    assert response.ai_available is True
    assert {match.symbol for match in response.results} == {"NVDA", "AAPL", "MSFT"}
    assert response.interpretation == "Buscás tecnológicas de Nasdaq."
    # La razón se compone en código con lo que efectivamente se verificó.
    assert response.results[0].match_reason == "Sector Tecnología, cotiza en NASDAQ"


async def test_sector_without_provider_equivalent_returns_nothing(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """`CRIPTO` no existe en el vocabulario del proveedor de acciones: filtrar por él no puede
    matchear ninguna fila del catálogo. Se corta ahí en vez de ignorar el filtro y devolver todo.
    """

    await _seed_catalog(db_session_factory, _TECH_CATALOG)
    service = TickerSearchService(
        db_session_factory,
        gemini_client=_gemini_client(
            _gemini_transport(
                {"interpretation": "Buscás cripto.", "sectors": ["CRIPTO"]}
            )
        ),
        system_prompt=_SYSTEM_PROMPT,
    )

    response = await service.search("cripto")

    assert response.results == []
    assert response.candidates_evaluated == 0


async def test_text_query_matches_symbol_or_name(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(db_session_factory, _TECH_CATALOG)
    service = TickerSearchService(
        db_session_factory,
        gemini_client=_gemini_client(
            _gemini_transport(
                {"interpretation": "Buscás Apple.", "text_query": "apple"}
            )
        ),
        system_prompt=_SYSTEM_PROMPT,
    )

    response = await service.search("acciones de apple")

    assert [match.symbol for match in response.results] == ["AAPL"]
    assert "apple" in response.results[0].match_reason.lower()


# --- Búsqueda: filtros por ratios ------------------------------------------------------------


async def test_numeric_filters_run_against_real_metrics(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(db_session_factory, _TECH_CATALOG)
    fmp = _FakeFMP(
        {
            "NVDA": _metrics("NVDA", pe=58.0, debt_to_equity=0.4),
            "AAPL": _metrics("AAPL", pe=12.0, debt_to_equity=0.3),
            "MSFT": _metrics("MSFT", pe=14.0, debt_to_equity=1.8),
        }
    )
    service = TickerSearchService(
        db_session_factory,
        gemini_client=_gemini_client(
            _gemini_transport(
                {
                    "interpretation": "Buscás tecnológicas baratas y sin mucha deuda.",
                    "sectors": ["TECNOLOGIA"],
                    "price_earnings_max": 15.0,
                    "debt_to_equity_max": 0.5,
                }
            )
        ),
        fmp_client=fmp,
        system_prompt=_SYSTEM_PROMPT,
    )

    response = await service.search("tecnológicas baratas sin deuda")

    assert response.metrics_available is True
    # NVDA queda afuera por P/E, MSFT por deuda.
    assert [match.symbol for match in response.results] == ["AAPL"]
    match = response.results[0]
    assert match.price_earnings == 12.0
    assert "P/E de 12.00x" in match.match_reason
    assert "Deuda/Equity de 0.30x" in match.match_reason
    assert response.unapplied_criteria == []


async def test_percentage_criteria_work_with_fractional_provider_values(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """FMP devuelve el ROE como fracción (0.25) o como porcentaje (25) según el endpoint. Sin
    normalizar, un ROE del 25% no pasaría un filtro de "mayor a 20".
    """

    await _seed_catalog(db_session_factory, _TECH_CATALOG)
    fmp = _FakeFMP(
        {
            "NVDA": _metrics("NVDA", roe=0.35),  # fracción
            "AAPL": _metrics("AAPL", roe=45.0),  # ya en porcentaje
            "MSFT": _metrics("MSFT", roe=0.05),
        }
    )
    service = TickerSearchService(
        db_session_factory,
        gemini_client=_gemini_client(
            _gemini_transport(
                {
                    "interpretation": "Buscás tecnológicas rentables.",
                    "sectors": ["TECNOLOGIA"],
                    "return_on_equity_min_pct": 20.0,
                }
            )
        ),
        fmp_client=fmp,
        system_prompt=_SYSTEM_PROMPT,
    )

    response = await service.search("tecnológicas rentables")

    assert {match.symbol for match in response.results} == {"NVDA", "AAPL"}


async def test_candidate_without_a_measured_ratio_is_excluded(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """La regla anti-alucinación de este endpoint: no se puede afirmar que un símbolo cumple un
    criterio que no se le pudo medir, así que queda afuera en vez de colarse como "podría cumplir".
    """

    await _seed_catalog(db_session_factory, _TECH_CATALOG)
    fmp = _FakeFMP(
        {
            "NVDA": _metrics("NVDA", pe=None),  # el proveedor no lo trajo
            "AAPL": _metrics("AAPL", pe=12.0),
            "MSFT": _metrics("MSFT", pe=13.0),
        }
    )
    service = TickerSearchService(
        db_session_factory,
        gemini_client=_gemini_client(
            _gemini_transport(
                {
                    "interpretation": "Buscás tecnológicas baratas.",
                    "sectors": ["TECNOLOGIA"],
                    "price_earnings_max": 20.0,
                }
            )
        ),
        fmp_client=fmp,
        system_prompt=_SYSTEM_PROMPT,
    )

    response = await service.search("tecnológicas baratas")

    assert "NVDA" not in {match.symbol for match in response.results}
    assert {match.symbol for match in response.results} == {"AAPL", "MSFT"}


async def test_free_cash_flow_criterion(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(db_session_factory, _TECH_CATALOG)
    fmp = _FakeFMP(
        {
            "NVDA": _metrics("NVDA", free_cash_flow=60_000_000_000),
            "AAPL": _metrics("AAPL", free_cash_flow=-2_000_000_000),
            "MSFT": _metrics("MSFT", free_cash_flow=70_000_000_000),
        }
    )
    service = TickerSearchService(
        db_session_factory,
        gemini_client=_gemini_client(
            _gemini_transport(
                {
                    "interpretation": "Buscás tecnológicas que generen caja.",
                    "sectors": ["TECNOLOGIA"],
                    "free_cash_flow_positive": True,
                }
            )
        ),
        fmp_client=fmp,
        system_prompt=_SYSTEM_PROMPT,
    )

    response = await service.search("tecnológicas que generen caja")

    assert {match.symbol for match in response.results} == {"NVDA", "MSFT"}
    assert "flujo de caja libre positivo" in response.results[0].match_reason


async def test_metrics_are_not_fetched_when_the_query_has_no_numeric_criteria(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """Una consulta que solo pide sector no debe gastar cinco endpoints de FMP por símbolo."""

    await _seed_catalog(db_session_factory, _TECH_CATALOG)
    fmp = _FakeFMP({})
    service = TickerSearchService(
        db_session_factory,
        gemini_client=_gemini_client(
            _gemini_transport(
                {"interpretation": "Buscás tecnológicas.", "sectors": ["TECNOLOGIA"]}
            )
        ),
        fmp_client=fmp,
        system_prompt=_SYSTEM_PROMPT,
    )

    response = await service.search("tecnológicas")

    assert fmp.calls == []
    assert len(response.results) == 3


async def test_metric_lookups_are_capped(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """El tope no es una optimización: `get_financial_metrics` pega a cinco endpoints por símbolo,
    así que sin él una consulta amplia serían cientos de requests dentro de un request HTTP.
    """

    await _seed_catalog(db_session_factory, _TECH_CATALOG)
    fmp = _FakeFMP({})
    service = TickerSearchService(
        db_session_factory,
        gemini_client=_gemini_client(
            _gemini_transport(
                {
                    "interpretation": "Buscás tecnológicas baratas.",
                    "sectors": ["TECNOLOGIA"],
                    "price_earnings_max": 100.0,
                }
            )
        ),
        fmp_client=fmp,
        max_metric_lookups=2,
        system_prompt=_SYSTEM_PROMPT,
    )

    response = await service.search("tecnológicas baratas")

    assert len(fmp.calls) == 2
    # Los candidatos evaluados localmente se reportan igual, para que "2 resultados" no se lea como
    # "el catálogo tiene 2".
    assert response.candidates_evaluated == 3


# --- Degradación -----------------------------------------------------------------------------


async def test_without_gemini_falls_back_to_text_search(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(db_session_factory, _TECH_CATALOG)
    service = TickerSearchService(db_session_factory, system_prompt=_SYSTEM_PROMPT)

    response = await service.search("NVDA")

    assert response.criteria_source == CriteriaSource.TEXT_FALLBACK
    assert response.ai_available is False
    assert response.interpretation is None
    assert [match.symbol for match in response.results] == ["NVDA"]
    assert response.degradation_reason is not None
    assert "GEMINI_API_KEY" in response.degradation_reason


async def test_gemini_failure_falls_back_to_text_search(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(db_session_factory, _TECH_CATALOG)
    service = TickerSearchService(
        db_session_factory,
        gemini_client=_gemini_client(_gemini_transport(status_code=500)),
        system_prompt=_SYSTEM_PROMPT,
    )

    response = await service.search("apple")

    assert response.criteria_source == CriteriaSource.TEXT_FALLBACK
    assert [match.symbol for match in response.results] == ["AAPL"]
    assert response.degradation_reason is not None
    assert "falló la consulta al modelo" in response.degradation_reason


async def test_invalid_model_output_falls_back_to_text_search(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(db_session_factory, _TECH_CATALOG)
    service = TickerSearchService(
        db_session_factory,
        gemini_client=_gemini_client(_gemini_transport(raw_text="no soy json")),
        system_prompt=_SYSTEM_PROMPT,
    )

    response = await service.search("apple")

    assert response.criteria_source == CriteriaSource.TEXT_FALLBACK
    assert [match.symbol for match in response.results] == ["AAPL"]


async def test_unstructurable_query_falls_back_to_text_search(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """El modelo respondió pero no reconoció ningún criterio ("hola"). No se traduce a "traeme
    todo": se busca por texto, que es lo único que la consulta soporta.
    """

    await _seed_catalog(db_session_factory, _TECH_CATALOG)
    service = TickerSearchService(
        db_session_factory,
        gemini_client=_gemini_client(
            _gemini_transport({"interpretation": "No hay criterios claros."})
        ),
        system_prompt=_SYSTEM_PROMPT,
    )

    response = await service.search("hola")

    assert response.criteria_source == CriteriaSource.TEXT_FALLBACK
    assert response.interpretation == "No hay criterios claros."
    assert response.results == []
    assert response.degradation_reason is not None


async def test_without_fmp_numeric_criteria_are_declared_unapplied(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """La degradación más delicada del endpoint: devolver una lista filtrada solo por sector,
    presentada como si cumpliera "P/E menor a 15", sería una respuesta falsa.
    """

    await _seed_catalog(db_session_factory, _TECH_CATALOG)
    service = TickerSearchService(
        db_session_factory,
        gemini_client=_gemini_client(
            _gemini_transport(
                {
                    "interpretation": "Buscás tecnológicas baratas.",
                    "sectors": ["TECNOLOGIA"],
                    "price_earnings_max": 15.0,
                    "free_cash_flow_positive": True,
                }
            )
        ),
        system_prompt=_SYSTEM_PROMPT,
    )

    response = await service.search("tecnológicas baratas que generen caja")

    assert response.metrics_available is False
    # Los resultados NO se vacían: el filtro de sector sí se aplicó y sirve.
    assert len(response.results) == 3
    assert response.unapplied_criteria == [
        "P/E menor a 15",
        "Flujo de caja libre positivo",
    ]
    assert response.degradation_reason is not None
    assert "FMP_API_KEY" in response.degradation_reason
    # Y la razón de cada match no menciona ningún ratio, porque ninguno se midió.
    assert "P/E" not in response.results[0].match_reason


async def test_a_provider_error_on_one_symbol_does_not_break_the_search(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    class _ExplodingFMP(_FakeFMP):
        async def get_financial_metrics(self, ticker: str) -> FinancialMetrics:
            self.calls.append(ticker)
            if ticker == "AAPL":
                raise RuntimeError("proveedor caído")
            return _metrics(ticker, pe=10.0)

    await _seed_catalog(db_session_factory, _TECH_CATALOG)
    service = TickerSearchService(
        db_session_factory,
        gemini_client=_gemini_client(
            _gemini_transport(
                {
                    "interpretation": "Buscás tecnológicas baratas.",
                    "sectors": ["TECNOLOGIA"],
                    "price_earnings_max": 20.0,
                }
            )
        ),
        fmp_client=_ExplodingFMP({}),
        system_prompt=_SYSTEM_PROMPT,
    )

    response = await service.search("tecnológicas baratas")

    # El símbolo que falló queda sin ratios y, por lo tanto, afuera. Los otros dos siguen.
    assert {match.symbol for match in response.results} == {"NVDA", "MSFT"}


# --- Endpoint --------------------------------------------------------------------------------


async def _auth_headers(client: httpx.AsyncClient, email: str) -> dict[str, str]:
    await client.post(
        "/api/v1/auth/register", json={"email": email, "password": "supersecreta1"}
    )
    login = await client.post(
        "/api/v1/auth/login", json={"email": email, "password": "supersecreta1"}
    )
    return {"Authorization": f"Bearer {login.json()['access_token']}"}


async def test_search_nl_requires_authentication(client: httpx.AsyncClient) -> None:
    response = await client.post(
        "/api/v1/tickers/search-nl", json={"query": "tecnológicas"}
    )

    assert response.status_code == 401


async def test_search_nl_endpoint_returns_valid_structure(
    client: httpx.AsyncClient, db_session_factory: async_sessionmaker[AsyncSession]
) -> None:
    """El servicio de la conftest no tiene Gemini ni FMP: la respuesta igual tiene forma válida y
    declara la degradación, en vez de un 503.
    """

    await _seed_catalog(db_session_factory, _TECH_CATALOG)
    headers = await _auth_headers(client, "search-nl@example.com")

    response = await client.post(
        "/api/v1/tickers/search-nl", json={"query": "microsoft"}, headers=headers
    )

    assert response.status_code == 200
    body = response.json()
    assert body["query"] == "microsoft"
    assert body["criteria_source"] == "TEXT_FALLBACK"
    assert body["ai_available"] is False
    assert [match["symbol"] for match in body["results"]] == ["MSFT"]
    assert body["results"][0]["sector"] == "TECNOLOGIA"
    assert body["results"][0]["sector_label"] == "Tecnología"


async def test_search_nl_rejects_an_empty_query(client: httpx.AsyncClient) -> None:
    headers = await _auth_headers(client, "search-nl-empty@example.com")

    response = await client.post(
        "/api/v1/tickers/search-nl", json={"query": "x"}, headers=headers
    )

    assert response.status_code == 422


async def test_search_nl_respects_the_limit(
    client: httpx.AsyncClient, db_session_factory: async_sessionmaker[AsyncSession]
) -> None:
    await _seed_catalog(db_session_factory, _TECH_CATALOG)
    headers = await _auth_headers(client, "search-nl-limit@example.com")

    response = await client.post(
        "/api/v1/tickers/search-nl",
        json={"query": "corporation", "limit": 1},
        headers=headers,
    )

    assert response.status_code == 200
    assert len(response.json()["results"]) == 1
