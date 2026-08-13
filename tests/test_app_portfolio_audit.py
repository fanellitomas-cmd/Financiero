"""Tests de `PortfolioAuditService` y `GET/POST /api/v1/watchlist/audit`.

Los contratos que este bloque promete y que son fáciles de romper sin darse cuenta:

  1. **Los cálculos son determinísticos y viven en código.** La misma watchlist da siempre la
     misma distribución, el mismo nivel de concentración y el mismo orden — el modelo solo redacta.
  2. **Nada se inventa.** Un sector desconocido es `SIN_CLASIFICAR`, una correlación que no se pudo
     medir no trae coeficiente, y un par sin histórico cae a la heurística por sector marcada como
     tal. Nunca a un número plausible.
  3. **Cada credencial ausente degrada solo su bloque.** Sin Gemini hay auditoría sin narrativa;
     sin FMP hay auditoría sin sectores; sin Polygon hay auditoría sin correlaciones medidas.
  4. **La caché sigue la composición de la cartera**, no solo el reloj: agregar un ticker invalida
     la auditoría vieja sin que nadie tenga que purgarla.
"""

from __future__ import annotations

import json
import uuid
from decimal import Decimal

import httpx
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.security import hash_password
from app.models.enums import AssetType, ExchangeType
from app.models.ticker import Ticker
from app.models.user import User
from app.models.watchlist import WatchlistItem
from app.schemas.intelligence import DataAvailability
from app.schemas.portfolio_audit import (
    CorrelationBasis,
    PortfolioSector,
    RiskLevel,
    SectorAllocation,
    sector_label,
)
from app.services.portfolio_audit_service import (
    PortfolioAuditService,
    build_concentration_risk,
    build_sector_allocation,
    pearson_correlation,
)
from app.services.portfolio_common import normalize_sector
from app.services.ticker_catalog_service import TickerCatalogService
from src.ingestion.fmp_client import FMPClient
from src.ingestion.gemini_client import GeminiClient
from src.ingestion.polygon_client import PolygonClient
from src.ingestion.schemas_raw import CompanyProfile, OhlcBar

_SYSTEM_PROMPT = "Sos un auditor de prueba. Devolvé el JSON pedido."


# --- Dobles ---------------------------------------------------------------------------------


class _FakeFMP(FMPClient):
    """Perfiles fijos por símbolo. Hereda de `FMPClient` para que el tipo del servicio se respete
    sin `type: ignore`, pero no llama a `super().__init__`: no hace falta cliente HTTP porque
    ningún método que pegue a la red se ejecuta.
    """

    def __init__(self, profiles: dict[str, str | None]) -> None:
        self._profiles = profiles
        self.calls: list[str] = []

    async def get_company_profile(self, ticker: str) -> CompanyProfile | None:
        self.calls.append(ticker)
        if ticker not in self._profiles:
            return None
        return CompanyProfile(
            ticker=ticker,
            company_name=f"{ticker} Inc.",
            sector=self._profiles[ticker],
            industry=None,
        )


class _FakePolygon(PolygonClient):
    def __init__(self, series: dict[str, list[float]]) -> None:
        self._series = series
        self.calls: list[str] = []

    async def get_daily_ohlc(
        self,
        ticker: str,
        *,
        start: object = None,
        end: object = None,
        limit: int = 5000,
    ) -> list[OhlcBar]:
        self.calls.append(ticker)
        closes = self._series.get(ticker, [])
        return [
            OhlcBar(
                # Un día de por medio entre velas; lo que importa es que los timestamps coincidan
                # entre series, porque el alineado es por fecha y no por posición.
                timestamp_ms=1_700_000_000_000 + index * 86_400_000,
                open=Decimal(str(close)),
                high=Decimal(str(close)),
                low=Decimal(str(close)),
                close=Decimal(str(close)),
                volume=Decimal(1000),
            )
            for index, close in enumerate(closes)
        ]


def _gemini_client(transport: httpx.MockTransport) -> GeminiClient:
    """Cliente real contra un transporte falso, igual que en el resto de la suite: así el parseo de
    la respuesta del proveedor también queda ejercitado, en vez de saltearse con un doble que
    devuelve el resultado ya armado.
    """

    return GeminiClient(
        "fake-key",
        http_client=httpx.AsyncClient(
            transport=transport,
            base_url="https://generativelanguage.googleapis.com/v1beta",
        ),
    )


def _gemini_transport(
    prompts: list[str] | None = None, *, summary: str = "Resumen de prueba."
) -> httpx.MockTransport:
    def handler(request: httpx.Request) -> httpx.Response:
        if prompts is not None:
            prompts.append(request.read().decode("utf-8"))
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "finishReason": "STOP",
                        "content": {
                            "parts": [{"text": json.dumps({"summary": summary})}]
                        },
                    }
                ]
            },
        )

    return httpx.MockTransport(handler)


def _gemini_invalid_transport() -> httpx.MockTransport:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "finishReason": "STOP",
                        "content": {"parts": [{"text": "no soy json"}]},
                    }
                ]
            },
        )

    return httpx.MockTransport(handler)


async def _seed_watchlist(
    session_factory: async_sessionmaker[AsyncSession],
    holdings: list[tuple[str, AssetType]],
) -> uuid.UUID:
    async with session_factory() as session:
        user = User(
            email=f"{uuid.uuid4()}@example.com", hashed_password=hash_password("x")
        )
        session.add(user)
        await session.flush()
        for ticker, asset_type in holdings:
            session.add(
                WatchlistItem(
                    user_id=user.id,
                    ticker=ticker,
                    asset_type=asset_type,
                    alert_threshold_pct=Decimal("3.0"),
                )
            )
        await session.commit()
        return user.id


async def _seed_catalog(
    session_factory: async_sessionmaker[AsyncSession],
    entries: list[tuple[str, str | None]],
) -> None:
    async with session_factory() as session:
        for symbol, sector in entries:
            session.add(
                Ticker(
                    symbol=symbol,
                    name=f"{symbol} Inc.",
                    exchange=ExchangeType.NASDAQ,
                    sector=sector,
                    active=True,
                )
            )
        await session.commit()


# --- Normalización de sectores --------------------------------------------------------------


def test_normalize_sector_maps_provider_vocabulary() -> None:
    assert normalize_sector("Technology") == PortfolioSector.TECNOLOGIA
    assert normalize_sector("  healthcare ") == PortfolioSector.SALUD
    assert normalize_sector("Consumer Defensive") == PortfolioSector.CONSUMO_BASICO


def test_normalize_sector_never_guesses() -> None:
    """Un sector que el proveedor renombre, o uno que no exista en la tabla, cae en
    `SIN_CLASIFICAR` — no en el sector más parecido.
    """

    assert normalize_sector(None) == PortfolioSector.SIN_CLASIFICAR
    assert normalize_sector("Quantum Widgets") == PortfolioSector.SIN_CLASIFICAR


# --- Distribución ---------------------------------------------------------------------------


def test_sector_allocation_is_equal_weighted_and_sorted() -> None:
    allocations = build_sector_allocation(
        {
            "NVDA": PortfolioSector.TECNOLOGIA,
            "MSFT": PortfolioSector.TECNOLOGIA,
            "AAPL": PortfolioSector.TECNOLOGIA,
            "JPM": PortfolioSector.SERVICIOS_FINANCIEROS,
        }
    )

    assert [allocation.sector for allocation in allocations] == [
        PortfolioSector.TECNOLOGIA,
        PortfolioSector.SERVICIOS_FINANCIEROS,
    ]
    assert allocations[0].weight_pct == 75.0
    assert allocations[0].tickers == ["AAPL", "MSFT", "NVDA"]
    assert allocations[1].weight_pct == 25.0
    assert sum(allocation.ticker_count for allocation in allocations) == 4


def test_sector_allocation_order_is_stable_on_ties() -> None:
    """Dos corridas de la misma cartera tienen que devolver el mismo orden: uno que baila haría
    que la UI reordene la torta sin que nada haya cambiado.
    """

    holdings = {
        "KO": PortfolioSector.CONSUMO_BASICO,
        "NVDA": PortfolioSector.TECNOLOGIA,
    }
    first = [item.sector for item in build_sector_allocation(holdings)]
    second = [
        item.sector
        for item in build_sector_allocation(dict(reversed(list(holdings.items()))))
    ]
    assert first == second


# --- Concentración --------------------------------------------------------------------------


def _allocation(sector: PortfolioSector, weight: float, count: int) -> SectorAllocation:
    return SectorAllocation(
        sector=sector,
        label=sector_label(sector),
        weight_pct=weight,
        ticker_count=count,
        tickers=[f"T{index}" for index in range(count)],
    )


def test_concentration_flags_dominant_sector() -> None:
    risk = build_concentration_risk(
        [
            _allocation(PortfolioSector.TECNOLOGIA, 70.0, 7),
            _allocation(PortfolioSector.SALUD, 30.0, 3),
        ]
    )

    assert risk is not None
    assert risk.level == RiskLevel.CRITICA
    assert "70% concentrado en Tecnología" in risk.headline
    assert risk.top_sector == PortfolioSector.TECNOLOGIA
    assert risk.distinct_sectors == 2


def test_concentration_catches_even_split_across_few_sectors() -> None:
    """El punto ciego del "sector dominante": 34/33/33 no tiene un dominante preocupante y es
    igual una cartera de tres sectores. El Herfindahl lo levanta.
    """

    risk = build_concentration_risk(
        [
            _allocation(PortfolioSector.TECNOLOGIA, 34.0, 1),
            _allocation(PortfolioSector.SALUD, 33.0, 1),
            _allocation(PortfolioSector.ENERGIA, 33.0, 1),
        ]
    )

    assert risk is not None
    assert risk.top_sector_weight_pct < 35.0  # por peso dominante daría BAJA
    assert risk.level == RiskLevel.MODERADA


def test_concentration_is_low_when_well_spread() -> None:
    risk = build_concentration_risk(
        [_allocation(sector, 100 / 6, 1) for sector in list(PortfolioSector)[:6]]
    )

    assert risk is not None
    assert risk.level == RiskLevel.BAJA
    assert any("Ningún sector supera" in note for note in risk.notes)


def test_concentration_notes_unclassified_assets() -> None:
    risk = build_concentration_risk(
        [
            _allocation(PortfolioSector.TECNOLOGIA, 50.0, 2),
            _allocation(PortfolioSector.SIN_CLASIFICAR, 50.0, 2),
        ]
    )

    assert risk is not None
    assert any("no tienen sector determinado" in note for note in risk.notes)


def test_concentration_of_empty_portfolio_is_none() -> None:
    assert build_concentration_risk([]) is None


# --- Correlación ----------------------------------------------------------------------------


def test_pearson_detects_perfectly_correlated_series() -> None:
    left = {1: 0.01, 2: -0.02, 3: 0.03, 4: 0.00}
    right = {1: 0.02, 2: -0.04, 3: 0.06, 4: 0.00}

    coefficient, observations = pearson_correlation(left, right)

    assert coefficient == 1.0
    assert observations == 4


def test_pearson_aligns_by_date_not_by_position() -> None:
    """Dos series con distinta cantidad de velas (un feriado, un listado más reciente) no deben
    compararse por índice: emparejar el 5 de una con el 5 de la otra compararía días distintos.
    """

    left = {1: 0.01, 2: -0.02, 3: 0.03}
    right = {2: -0.02, 3: 0.03}

    coefficient, observations = pearson_correlation(left, right)

    assert observations == 2
    assert coefficient == 1.0


def test_pearson_refuses_to_answer_without_variance() -> None:
    """Una serie constante no está "correlacionada 0": no es medible. Devolver 0 haría pasar por
    medido algo que no lo está.
    """

    flat = {1: 0.0, 2: 0.0, 3: 0.0}
    moving = {1: 0.01, 2: -0.02, 3: 0.03}

    coefficient, observations = pearson_correlation(flat, moving)

    assert coefficient is None
    assert observations == 3


def test_pearson_needs_at_least_two_shared_days() -> None:
    assert pearson_correlation({1: 0.01}, {1: 0.02}) == (None, 1)


# --- Servicio: composición y degradación ----------------------------------------------------


async def test_audit_of_empty_watchlist_is_valid_and_explicit(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    user_id = await _seed_watchlist(db_session_factory, [])
    service = PortfolioAuditService(db_session_factory, system_prompt=_SYSTEM_PROMPT)

    audit = await service.get_audit(user_id)

    assert audit.position_count == 0
    assert audit.availability == DataAvailability.UNAVAILABLE
    assert audit.sector_allocation == []
    assert audit.risk_concentration is None
    assert audit.degradation_reason is not None
    assert "watchlist" in audit.degradation_reason.lower()


async def test_audit_uses_catalog_sectors_without_touching_provider(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """El catálogo local es la primera fuente: un símbolo ya clasificado no vuelve a costar una
    llamada a FMP en cada auditoría de cada usuario.
    """

    await _seed_catalog(
        db_session_factory, [("NVDA", "Technology"), ("JPM", "Financial Services")]
    )
    user_id = await _seed_watchlist(
        db_session_factory, [("NVDA", AssetType.STOCK), ("JPM", AssetType.STOCK)]
    )
    fmp = _FakeFMP({})
    service = PortfolioAuditService(
        db_session_factory, fmp_client=fmp, system_prompt=_SYSTEM_PROMPT
    )

    audit = await service.get_audit(user_id)

    assert fmp.calls == []
    assert {allocation.sector for allocation in audit.sector_allocation} == {
        PortfolioSector.TECNOLOGIA,
        PortfolioSector.SERVICIOS_FINANCIEROS,
    }


async def test_audit_resolves_missing_sectors_and_persists_them(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """Write-through: el sector resuelto contra FMP queda en el catálogo para la próxima."""

    await _seed_catalog(db_session_factory, [("NVDA", None), ("KO", None)])
    user_id = await _seed_watchlist(
        db_session_factory, [("NVDA", AssetType.STOCK), ("KO", AssetType.STOCK)]
    )
    fmp = _FakeFMP({"NVDA": "Technology", "KO": "Consumer Defensive"})
    service = PortfolioAuditService(
        db_session_factory, fmp_client=fmp, system_prompt=_SYSTEM_PROMPT
    )

    await service.get_audit(user_id)

    assert sorted(fmp.calls) == ["KO", "NVDA"]
    stored = await TickerCatalogService(db_session_factory).find_sectors(["NVDA", "KO"])
    assert stored == {"NVDA": "Technology", "KO": "Consumer Defensive"}


async def test_crypto_is_classified_without_asking_the_stock_provider(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    user_id = await _seed_watchlist(db_session_factory, [("BTC-USD", AssetType.CRYPTO)])
    fmp = _FakeFMP({})
    service = PortfolioAuditService(
        db_session_factory, fmp_client=fmp, system_prompt=_SYSTEM_PROMPT
    )

    audit = await service.get_audit(user_id)

    assert fmp.calls == []
    assert audit.sector_allocation[0].sector == PortfolioSector.CRIPTO


async def test_audit_without_fmp_declares_sectors_unavailable(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    user_id = await _seed_watchlist(
        db_session_factory, [("NVDA", AssetType.STOCK), ("MSFT", AssetType.STOCK)]
    )
    service = PortfolioAuditService(db_session_factory, system_prompt=_SYSTEM_PROMPT)

    audit = await service.get_audit(user_id)

    assert audit.sector_data_available is False
    assert audit.availability == DataAvailability.UNAVAILABLE
    assert audit.sector_allocation[0].sector == PortfolioSector.SIN_CLASIFICAR
    assert audit.degradation_reason is not None
    assert "FMP_API_KEY" in audit.degradation_reason


async def test_audit_measures_correlation_against_real_prices(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(
        db_session_factory, [("NVDA", "Technology"), ("AMD", "Technology")]
    )
    user_id = await _seed_watchlist(
        db_session_factory, [("NVDA", AssetType.STOCK), ("AMD", AssetType.STOCK)]
    )
    # Dos series que se mueven exactamente igual, con suficientes días para superar el mínimo.
    closes = [100.0 + (index % 5) * 3 + index for index in range(40)]
    polygon = _FakePolygon({"NVDA": closes, "AMD": [value * 2 for value in closes]})
    service = PortfolioAuditService(
        db_session_factory,
        polygon_client=polygon,
        min_correlation_observations=10,
        system_prompt=_SYSTEM_PROMPT,
    )

    audit = await service.get_audit(user_id)

    assert audit.correlation_measured is True
    assert len(audit.correlation_warnings) == 1
    warning = audit.correlation_warnings[0]
    assert warning.basis == CorrelationBasis.PRICE_HISTORY
    assert warning.coefficient == 1.0
    assert warning.tickers == ["AMD", "NVDA"]


async def test_low_correlation_produces_no_warning(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(
        db_session_factory, [("NVDA", "Technology"), ("KO", "Consumer Defensive")]
    )
    user_id = await _seed_watchlist(
        db_session_factory, [("NVDA", AssetType.STOCK), ("KO", AssetType.STOCK)]
    )
    polygon = _FakePolygon(
        {
            "NVDA": [100 + (index % 7) * 4 for index in range(40)],
            "KO": [100 + (index % 3) * 2 for index in range(40)],
        }
    )
    service = PortfolioAuditService(
        db_session_factory,
        polygon_client=polygon,
        min_correlation_observations=10,
        system_prompt=_SYSTEM_PROMPT,
    )

    audit = await service.get_audit(user_id)

    assert audit.correlation_warnings == []


async def test_without_price_history_falls_back_to_sector_heuristic(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """Sin Polygon la advertencia igual se emite, pero declarada como inferencia por sector y sin
    coeficiente: dos bancos comparten riesgo aunque falte el histórico, y callarlo sería peor.
    """

    await _seed_catalog(
        db_session_factory,
        [("JPM", "Financial Services"), ("BAC", "Financial Services")],
    )
    user_id = await _seed_watchlist(
        db_session_factory, [("JPM", AssetType.STOCK), ("BAC", AssetType.STOCK)]
    )
    service = PortfolioAuditService(db_session_factory, system_prompt=_SYSTEM_PROMPT)

    audit = await service.get_audit(user_id)

    assert audit.correlation_measured is False
    assert len(audit.correlation_warnings) == 1
    warning = audit.correlation_warnings[0]
    assert warning.basis == CorrelationBasis.SECTOR
    assert warning.coefficient is None
    assert warning.observations is None


async def test_insufficient_history_is_not_reported_as_measured(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """Bajar histórico no es medir: con dos series que casi no se solapan no hay correlación
    calculada, y declarar `correlation_measured=True` haría que la ausencia de advertencias se
    leyera como "los medimos y no correlacionan".
    """

    await _seed_catalog(
        db_session_factory, [("NVDA", "Technology"), ("AMD", "Technology")]
    )
    user_id = await _seed_watchlist(
        db_session_factory, [("NVDA", AssetType.STOCK), ("AMD", AssetType.STOCK)]
    )
    polygon = _FakePolygon({"NVDA": [100.0, 101.0, 103.0], "AMD": [50.0, 50.5, 51.5]})
    service = PortfolioAuditService(
        db_session_factory,
        polygon_client=polygon,
        min_correlation_observations=30,
        system_prompt=_SYSTEM_PROMPT,
    )

    audit = await service.get_audit(user_id)

    assert polygon.calls  # sí se pidió el histórico
    assert audit.correlation_measured is False
    # El par cae a la heurística por sector, declarada como tal.
    assert audit.correlation_warnings[0].basis == CorrelationBasis.SECTOR


async def test_unclassified_assets_do_not_generate_sector_warnings(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """Dos símbolos cuyo sector no se conoce no comparten un sector: comparten que no se sabe."""

    user_id = await _seed_watchlist(
        db_session_factory, [("AAA", AssetType.STOCK), ("BBB", AssetType.STOCK)]
    )
    service = PortfolioAuditService(db_session_factory, system_prompt=_SYSTEM_PROMPT)

    audit = await service.get_audit(user_id)

    assert audit.correlation_warnings == []


async def test_suggestions_avoid_sectors_already_present(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(
        db_session_factory,
        [("NVDA", "Technology"), ("MSFT", "Technology"), ("JNJ", "Healthcare")],
    )
    user_id = await _seed_watchlist(
        db_session_factory,
        [
            ("NVDA", AssetType.STOCK),
            ("MSFT", AssetType.STOCK),
            ("JNJ", AssetType.STOCK),
        ],
    )
    service = PortfolioAuditService(db_session_factory, system_prompt=_SYSTEM_PROMPT)

    audit = await service.get_audit(user_id)

    suggested = {suggestion.sector for suggestion in audit.diversification_suggestions}
    assert len(suggested) == 3
    # Salud ya pesa 33%, muy por encima del umbral de subrepresentación.
    assert PortfolioSector.SALUD not in suggested
    assert PortfolioSector.TECNOLOGIA not in suggested


async def test_narrative_is_generated_from_the_computed_blocks(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(db_session_factory, [("NVDA", "Technology")])
    user_id = await _seed_watchlist(
        db_session_factory, [("NVDA", AssetType.STOCK), ("BTC-USD", AssetType.CRYPTO)]
    )
    prompts: list[str] = []
    service = PortfolioAuditService(
        db_session_factory,
        gemini_client=_gemini_client(
            _gemini_transport(
                prompts, summary="Tu lista se apoya sobre todo en Tecnología."
            )
        ),
        system_prompt=_SYSTEM_PROMPT,
    )

    audit = await service.get_audit(user_id)

    assert audit.ai_summary_available is True
    assert audit.ai_summary == "Tu lista se apoya sobre todo en Tecnología."
    # El prompt tiene que llevar la aclaración de ponderación: sin ella el modelo escribiría "el
    # 50% de tu capital", que es una afirmación que estos datos no sostienen.
    assert "EQUIPONDERADA POR CANTIDAD DE ACTIVOS" in prompts[0]
    assert "Tecnolog" in prompts[0]


async def test_audit_without_gemini_keeps_every_computed_block(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(
        db_session_factory, [("NVDA", "Technology"), ("JPM", "Financial Services")]
    )
    user_id = await _seed_watchlist(
        db_session_factory, [("NVDA", AssetType.STOCK), ("JPM", AssetType.STOCK)]
    )
    service = PortfolioAuditService(db_session_factory, system_prompt=_SYSTEM_PROMPT)

    audit = await service.get_audit(user_id)

    assert audit.ai_summary is None
    assert audit.ai_summary_available is False
    assert audit.degradation_reason is not None
    assert "GEMINI_API_KEY" in audit.degradation_reason
    # Lo determinístico sobrevive intacto.
    assert len(audit.sector_allocation) == 2
    assert audit.risk_concentration is not None
    assert audit.diversification_suggestions


async def test_invalid_model_output_degrades_only_the_narrative(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(db_session_factory, [("NVDA", "Technology")])
    user_id = await _seed_watchlist(db_session_factory, [("NVDA", AssetType.STOCK)])
    service = PortfolioAuditService(
        db_session_factory,
        gemini_client=_gemini_client(_gemini_invalid_transport()),
        system_prompt=_SYSTEM_PROMPT,
    )

    audit = await service.get_audit(user_id)

    assert audit.ai_summary is None
    assert audit.risk_concentration is not None
    assert audit.degradation_reason is not None
    assert "no se pudo interpretar" in audit.degradation_reason


# --- Caché ----------------------------------------------------------------------------------


async def test_second_call_is_served_from_cache(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(db_session_factory, [("NVDA", "Technology")])
    user_id = await _seed_watchlist(db_session_factory, [("NVDA", AssetType.STOCK)])
    prompts: list[str] = []
    service = PortfolioAuditService(
        db_session_factory,
        gemini_client=_gemini_client(_gemini_transport(prompts)),
        system_prompt=_SYSTEM_PROMPT,
    )

    first = await service.get_audit(user_id)
    second = await service.get_audit(user_id)

    assert first.served_from_cache is False
    assert second.served_from_cache is True
    assert len(prompts) == 1


async def test_changing_the_watchlist_invalidates_the_cache(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """La clave de caché incluye la composición de la cartera, así que agregar un ticker fuerza el
    recálculo sin que la API tenga que acordarse de purgarla.
    """

    await _seed_catalog(
        db_session_factory, [("NVDA", "Technology"), ("JNJ", "Healthcare")]
    )
    user_id = await _seed_watchlist(db_session_factory, [("NVDA", AssetType.STOCK)])
    prompts: list[str] = []
    service = PortfolioAuditService(
        db_session_factory,
        gemini_client=_gemini_client(_gemini_transport(prompts)),
        system_prompt=_SYSTEM_PROMPT,
    )

    first = await service.get_audit(user_id)
    async with db_session_factory() as session:
        session.add(
            WatchlistItem(
                user_id=user_id,
                ticker="JNJ",
                asset_type=AssetType.STOCK,
                alert_threshold_pct=Decimal("3.0"),
            )
        )
        await session.commit()
    second = await service.get_audit(user_id)

    assert first.position_count == 1
    assert second.position_count == 2
    assert second.served_from_cache is False
    assert len(prompts) == 2


async def test_force_refresh_ignores_the_cache(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_catalog(db_session_factory, [("NVDA", "Technology")])
    user_id = await _seed_watchlist(db_session_factory, [("NVDA", AssetType.STOCK)])
    prompts: list[str] = []
    service = PortfolioAuditService(
        db_session_factory,
        gemini_client=_gemini_client(_gemini_transport(prompts)),
        system_prompt=_SYSTEM_PROMPT,
    )

    await service.get_audit(user_id)
    refreshed = await service.get_audit(user_id, force_refresh=True)

    assert refreshed.served_from_cache is False
    assert len(prompts) == 2


# --- Endpoint -------------------------------------------------------------------------------


async def _auth_headers(client: httpx.AsyncClient, email: str) -> dict[str, str]:
    await client.post(
        "/api/v1/auth/register", json={"email": email, "password": "supersecreta1"}
    )
    login = await client.post(
        "/api/v1/auth/login", json={"email": email, "password": "supersecreta1"}
    )
    return {"Authorization": f"Bearer {login.json()['access_token']}"}


async def test_audit_endpoint_requires_authentication(
    client: httpx.AsyncClient,
) -> None:
    assert (await client.get("/api/v1/watchlist/audit")).status_code == 401
    assert (await client.post("/api/v1/watchlist/audit")).status_code == 401


async def test_audit_endpoint_returns_valid_structure_for_empty_watchlist(
    client: httpx.AsyncClient,
) -> None:
    headers = await _auth_headers(client, "audit-empty@example.com")

    response = await client.get("/api/v1/watchlist/audit", headers=headers)

    assert response.status_code == 200
    body = response.json()
    assert body["position_count"] == 0
    assert body["availability"] == "UNAVAILABLE"
    assert body["weighting_basis"] == "EQUAL_WEIGHT_BY_COUNT"
    assert body["sector_allocation"] == []


async def test_audit_endpoint_reflects_the_users_own_watchlist(
    client: httpx.AsyncClient,
) -> None:
    headers = await _auth_headers(client, "audit-owner@example.com")
    for ticker in ("NVDA", "MSFT", "BTC-USD"):
        await client.post(
            "/api/v1/watchlist",
            json={
                "ticker": ticker,
                "asset_type": "CRYPTO" if ticker == "BTC-USD" else "STOCK",
            },
            headers=headers,
        )

    response = await client.get("/api/v1/watchlist/audit", headers=headers)

    assert response.status_code == 200
    body = response.json()
    assert body["position_count"] == 3
    sectors = {item["sector"]: item for item in body["sector_allocation"]}
    assert "CRIPTO" in sectors
    assert sectors["CRIPTO"]["tickers"] == ["BTC-USD"]
    assert sectors["CRIPTO"]["label"] == "Cripto"


async def test_audit_post_recalculates(client: httpx.AsyncClient) -> None:
    headers = await _auth_headers(client, "audit-refresh@example.com")
    await client.post(
        "/api/v1/watchlist",
        json={"ticker": "NVDA", "asset_type": "STOCK"},
        headers=headers,
    )

    first = await client.get("/api/v1/watchlist/audit", headers=headers)
    cached = await client.get("/api/v1/watchlist/audit", headers=headers)
    refreshed = await client.post("/api/v1/watchlist/audit", headers=headers)

    assert first.json()["served_from_cache"] is False
    assert cached.json()["served_from_cache"] is True
    assert refreshed.status_code == 200
    assert refreshed.json()["served_from_cache"] is False


async def test_audit_never_leaks_another_users_portfolio(
    client: httpx.AsyncClient,
) -> None:
    owner = await _auth_headers(client, "audit-a@example.com")
    other = await _auth_headers(client, "audit-b@example.com")
    await client.post(
        "/api/v1/watchlist",
        json={"ticker": "NVDA", "asset_type": "STOCK"},
        headers=owner,
    )

    response = await client.get("/api/v1/watchlist/audit", headers=other)

    assert response.json()["position_count"] == 0
