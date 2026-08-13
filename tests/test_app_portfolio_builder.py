"""Tests del Constructor de Portafolios: reparto del presupuesto, precios esperados, sectores,
concentración y retorno ponderado.

Los tests de aritmética verifican el NÚMERO, no que el campo exista: un reparto que devuelve la forma
correcta con las cuentas mal es exactamente el bug que este módulo no puede tener.
"""

from __future__ import annotations

from datetime import date, datetime, timezone

import httpx
import pytest
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.enums import AssetType
from app.schemas.intelligence import DataAvailability
from app.schemas.market import OhlcBarOut, TickerHistory, TickerQuote
from app.schemas.portfolio_audit import PortfolioSector, RiskLevel, WeightingBasis
from app.schemas.portfolio_builder import (
    AllocationType,
    PortfolioItemInput,
    PortfolioSimulationRequest,
    PriceSource,
    UnitRounding,
)
from app.services.portfolio_builder_service import (
    PortfolioBuilderService,
    build_sector_amounts,
    target_amount,
    units_for,
    weighted_return_1y,
)
from src.ingestion.schemas_raw import CompanyProfile
from src.validation.domain_models import DataStatus

_TODAY = date(2026, 8, 13)


# --- Dobles ------------------------------------------------------------------------------------


class _FakeMarketData:
    """Doble de `MarketDataService`. Devuelve precios y velas por símbolo.

    `histories` mapea ticker -> lista de (días atrás, cierre). Se expresa en días atrás y no en fechas
    absolutas para que los tests no se rompan cuando cambie el calendario.
    """

    def __init__(
        self,
        *,
        prices: dict[str, float | None] | None = None,
        histories: dict[str, list[tuple[int, float]]] | None = None,
        raise_on_quotes: bool = False,
        raise_on_history: bool = False,
    ) -> None:
        self.prices = prices or {}
        self.histories = histories or {}
        self.raise_on_quotes = raise_on_quotes
        self.raise_on_history = raise_on_history
        self.quote_calls: list[list[str]] = []
        self.history_calls: list[str] = []

    async def get_quotes(self, items: list[tuple[str, AssetType]]) -> list[TickerQuote]:
        if self.raise_on_quotes:
            raise RuntimeError("proveedor caído")
        self.quote_calls.append([ticker for ticker, _ in items])
        return [
            TickerQuote(
                ticker=ticker,
                last_price=self.prices.get(ticker),
                day_change_pct=None,
                status=DataStatus.OK
                if self.prices.get(ticker) is not None
                else DataStatus.ERROR_API,
            )
            for ticker, _ in items
        ]

    async def get_history(
        self, ticker: str, *, start: date, end: date
    ) -> TickerHistory:
        if self.raise_on_history:
            raise RuntimeError("histórico caído")
        self.history_calls.append(ticker)
        bars = self.histories.get(ticker, [])
        return TickerHistory(
            ticker=ticker,
            start=start,
            end=end,
            bars=[
                OhlcBarOut(
                    t=int(
                        datetime(
                            _TODAY.year, _TODAY.month, _TODAY.day, tzinfo=timezone.utc
                        ).timestamp()
                        * 1000
                    )
                    - days_ago * 86_400_000,
                    o=close,
                    h=close,
                    l=close,
                    c=close,
                    v=1000.0,
                )
                for days_ago, close in bars
            ],
        )


class _FakeFMP:
    def __init__(self, sectors: dict[str, str] | None = None) -> None:
        self.sectors = sectors or {}

    async def get_company_profile(self, ticker: str) -> CompanyProfile | None:
        raw = self.sectors.get(ticker)
        if raw is None:
            return None
        return CompanyProfile(
            ticker=ticker, company_name=f"{ticker} Inc.", sector=raw, industry=None
        )


def _service(
    session_factory: async_sessionmaker[AsyncSession],
    *,
    market: _FakeMarketData | None = None,
    fmp: _FakeFMP | None = None,
) -> PortfolioBuilderService:
    # Los dobles implementan la misma interfaz que consume el servicio, pero no heredan de las
    # clases reales: mypy necesita el ignore y el motivo va acá, no pegado al comentario del ignore
    # (un texto extra en la misma línea lo invalida).
    return PortfolioBuilderService(
        session_factory,
        market_data_service=market,  # type: ignore[arg-type]
        fmp_client=fmp,  # type: ignore[arg-type]
    )


def _item(
    ticker: str,
    kind: AllocationType,
    value: float,
    *,
    custom_price: float | None = None,
    asset_type: AssetType = AssetType.STOCK,
) -> PortfolioItemInput:
    return PortfolioItemInput(
        ticker=ticker,
        asset_type=asset_type,
        allocation_type=kind,
        allocation_value=value,
        custom_price=custom_price,
    )


def _request(budget: float, *items: PortfolioItemInput) -> PortfolioSimulationRequest:
    return PortfolioSimulationRequest(total_budget=budget, items=list(items))


async def _auth(client: httpx.AsyncClient, email: str) -> dict[str, str]:
    await client.post(
        "/api/v1/auth/register", json={"email": email, "password": "supersecreta1"}
    )
    login = await client.post(
        "/api/v1/auth/login", json={"email": email, "password": "supersecreta1"}
    )
    return {"Authorization": f"Bearer {login.json()['access_token']}"}


# --- Aritmética del reparto --------------------------------------------------------------------


class TestTargetAmount:
    def test_unidades_se_traducen_a_dolares_con_el_precio(self) -> None:
        item = _item("NVDA", AllocationType.UNITS, 10)
        assert target_amount(item, budget=10_000, price=95.0) == 950.0

    def test_un_monto_viaja_tal_cual(self) -> None:
        item = _item("NVDA", AllocationType.AMOUNT_USD, 2_500)
        assert target_amount(item, budget=10_000, price=95.0) == 2_500.0

    def test_un_porcentaje_se_mide_sobre_el_presupuesto(self) -> None:
        item = _item("NVDA", AllocationType.PERCENTAGE, 25)
        assert target_amount(item, budget=10_000, price=95.0) == 2_500.0


class TestUnitsFor:
    def test_se_redondea_hacia_abajo(self) -> None:
        # 1000 / 300 = 3,33 -> 3 unidades, no 3 ni 4 por redondeo simétrico.
        assert units_for(1_000, 300) == 3

    def test_un_monto_que_no_alcanza_da_cero(self) -> None:
        assert units_for(50, 300) == 0

    def test_un_precio_infimo_no_produce_millones_de_unidades(self) -> None:
        """Por debajo de un centavo la cantidad deja de representar una operación real."""

        assert units_for(1_000, 0.0001) == 0

    def test_un_monto_exacto_no_pierde_una_unidad_por_flotante(self) -> None:
        assert units_for(900, 300) == 3


# --- Reparto completo ---------------------------------------------------------------------------


class TestSimulateMarketPrices:
    async def test_reparte_con_precios_de_mercado(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        market = _FakeMarketData(prices={"NVDA": 300.0, "KO": 60.0})
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(
                10_000,
                _item("NVDA", AllocationType.PERCENTAGE, 60),
                _item("KO", AllocationType.AMOUNT_USD, 3_000),
            ),
            today=_TODAY,
        )

        nvda, ko = result.items
        # 60% de 10.000 = 6.000; 6.000 / 300 = 20 unidades exactas.
        assert (nvda.ticker, nvda.units, nvda.invested_amount) == ("NVDA", 20, 6_000.0)
        # 3.000 / 60 = 50 unidades exactas.
        assert (ko.ticker, ko.units, ko.invested_amount) == ("KO", 50, 3_000.0)
        assert result.allocated_amount == 9_000.0
        assert result.cash_unallocated == 1_000.0
        assert result.cash_pct == 10.0

    async def test_los_porcentajes_se_miden_sobre_lo_asignado_y_suman_cien(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        """El efectivo viaja aparte en `cash_pct`, así que las posiciones reparten el 100% de lo
        invertido: una torta que sume 90% obligaría al cliente a inventar el resto.
        """

        market = _FakeMarketData(prices={"NVDA": 300.0, "KO": 60.0})
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(
                10_000,
                _item("NVDA", AllocationType.PERCENTAGE, 60),
                _item("KO", AllocationType.AMOUNT_USD, 3_000),
            ),
            today=_TODAY,
        )

        total = sum(item.percentage_of_total for item in result.items)
        assert total == pytest.approx(100.0, abs=0.02)

    async def test_la_fraccion_que_no_llega_queda_en_efectivo(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        market = _FakeMarketData(prices={"NVDA": 300.0})
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(1_000, _item("NVDA", AllocationType.PERCENTAGE, 100)),
            today=_TODAY,
        )

        item = result.items[0]
        assert item.units == 3
        assert item.invested_amount == 900.0
        assert result.cash_unallocated == 100.0
        assert result.unit_rounding == UnitRounding.FLOOR_TO_WHOLE_UNITS

    async def test_una_posicion_que_no_alcanza_una_unidad_lo_declara(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        market = _FakeMarketData(prices={"BRK": 700_000.0})
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(1_000, _item("BRK", AllocationType.PERCENTAGE, 100)),
            today=_TODAY,
        )

        item = result.items[0]
        assert item.units == 0
        assert item.invested_amount == 0.0
        assert item.note is not None
        assert "una unidad entera" in item.note
        # El presupuesto entero queda como efectivo: no se inventó una fracción de acción.
        assert result.cash_unallocated == 1_000.0

    async def test_un_simbolo_repetido_no_se_cuenta_dos_veces(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        """Sumarlo dos veces produciría una concentración que el usuario no pidió."""

        market = _FakeMarketData(prices={"NVDA": 100.0})
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(
                10_000,
                _item("NVDA", AllocationType.AMOUNT_USD, 1_000),
                _item("nvda", AllocationType.AMOUNT_USD, 5_000),
            ),
            today=_TODAY,
        )

        assert len(result.items) == 1
        # Gana la primera aparición, que es la que el usuario escribió primero.
        assert result.items[0].invested_amount == 1_000.0

    async def test_el_ticker_se_normaliza_a_mayusculas(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        market = _FakeMarketData(prices={"NVDA": 100.0})
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(1_000, _item(" nvda ", AllocationType.UNITS, 5)), today=_TODAY
        )

        assert result.items[0].ticker == "NVDA"
        assert result.items[0].units == 5


class TestSimulateCustomPrices:
    async def test_el_precio_esperado_reemplaza_al_de_mercado(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        market = _FakeMarketData(prices={"NVDA": 300.0})
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(
                10_000,
                _item("NVDA", AllocationType.PERCENTAGE, 100, custom_price=200.0),
            ),
            today=_TODAY,
        )

        item = result.items[0]
        assert item.is_custom_price is True
        assert item.price_source == PriceSource.CUSTOM
        assert item.effective_price == 200.0
        # 10.000 / 200 = 50 unidades, no 33 (que es lo que daría el precio de mercado).
        assert item.units == 50
        assert item.invested_amount == 10_000.0

    async def test_el_precio_de_mercado_viaja_igual_para_poder_comparar(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        """Con un precio esperado, ver el de mercado al lado es lo que permite juzgar el supuesto."""

        market = _FakeMarketData(prices={"NVDA": 300.0})
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(
                10_000,
                _item("NVDA", AllocationType.PERCENTAGE, 100, custom_price=200.0),
            ),
            today=_TODAY,
        )

        item = result.items[0]
        assert item.market_price == 300.0
        assert item.effective_price == 200.0

    async def test_sin_proveedor_una_cartera_de_precios_esperados_se_calcula_entera(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        """Es el caso de uso central de la feature: exigir credenciales para atenderlo dejaría
        inalcanzable justamente lo que la distingue de la Auditoría.
        """

        service = _service(db_session_factory, market=None)

        result = await service.simulate(
            _request(
                10_000,
                _item("NVDA", AllocationType.PERCENTAGE, 50, custom_price=250.0),
                _item("KO", AllocationType.PERCENTAGE, 50, custom_price=50.0),
            ),
            today=_TODAY,
        )

        # El reparto de capital está COMPLETO sin proveedor…
        assert [item.units for item in result.items] == [20, 100]
        assert result.allocated_amount == 10_000.0
        assert result.cash_unallocated == 0.0
        # …y lo que queda degradado es solo el sector, que se declara aparte. Las dos cosas son
        # distintas y la respuesta no las mezcla en un único "no disponible".
        assert result.availability == DataAvailability.PARTIAL
        assert result.degradation_reason is not None
        assert "sector" in result.degradation_reason
        # Sin proveedor no hay `market_price` con el que comparar, y se dice en vez de repetir el
        # esperado como si fuera de mercado.
        assert all(item.market_price is None for item in result.items)

    async def test_un_precio_esperado_infimo_no_produce_millones_de_unidades(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        service = _service(db_session_factory, market=None)

        result = await service.simulate(
            _request(
                10_000,
                _item("PENNY", AllocationType.PERCENTAGE, 100, custom_price=0.0001),
            ),
            today=_TODAY,
        )

        item = result.items[0]
        assert item.units == 0
        assert item.note is not None
        assert "centavo" in item.note

    async def test_la_nota_aclara_que_el_retorno_no_sale_del_precio_esperado(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        service = _service(db_session_factory, market=None)

        result = await service.simulate(
            _request(1_000, _item("NVDA", AllocationType.UNITS, 2, custom_price=100.0)),
            today=_TODAY,
        )

        assert any("precios REALES" in note for note in result.notes)


class TestOverBudget:
    async def test_pedir_mas_que_el_presupuesto_no_deja_efectivo_negativo(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        """Un efectivo negativo afirmaría que hay plata negativa; recortar en silencio obligaría a
        elegir a qué posición sacarle capital, que es una decisión del usuario.
        """

        market = _FakeMarketData(prices={"NVDA": 100.0, "KO": 100.0})
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(
                1_000,
                _item("NVDA", AllocationType.AMOUNT_USD, 800),
                _item("KO", AllocationType.AMOUNT_USD, 800),
            ),
            today=_TODAY,
        )

        assert result.allocated_amount == 1_600.0
        assert result.cash_unallocated == 0.0
        assert result.over_budget_amount == 600.0
        assert any("supera el presupuesto" in note for note in result.notes)

    async def test_las_posiciones_no_se_recortan(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        market = _FakeMarketData(prices={"NVDA": 100.0, "KO": 100.0})
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(
                1_000,
                _item("NVDA", AllocationType.AMOUNT_USD, 800),
                _item("KO", AllocationType.AMOUNT_USD, 800),
            ),
            today=_TODAY,
        )

        assert [item.units for item in result.items] == [8, 8]

    async def test_dentro_del_presupuesto_no_hay_excedente(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        market = _FakeMarketData(prices={"NVDA": 100.0})
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(1_000, _item("NVDA", AllocationType.AMOUNT_USD, 500)),
            today=_TODAY,
        )

        assert result.over_budget_amount is None


# --- Sectores ------------------------------------------------------------------------------------


class TestSectorAllocation:
    async def test_reparte_por_capital_y_no_por_cantidad_de_activos(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        """La diferencia con la Auditoría: acá dos posiciones chicas de un sector no pesan lo mismo
        que una grande de otro.
        """

        market = _FakeMarketData(prices={"NVDA": 100.0, "KO": 100.0, "PEP": 100.0})
        fmp = _FakeFMP(
            {
                "NVDA": "Technology",
                "KO": "Consumer Defensive",
                "PEP": "Consumer Defensive",
            }
        )
        service = _service(db_session_factory, market=market, fmp=fmp)

        result = await service.simulate(
            _request(
                10_000,
                _item("NVDA", AllocationType.AMOUNT_USD, 8_000),
                _item("KO", AllocationType.AMOUNT_USD, 1_000),
                _item("PEP", AllocationType.AMOUNT_USD, 1_000),
            ),
            today=_TODAY,
        )

        by_sector = {
            item.sector: item.percentage_of_total for item in result.sector_allocation
        }
        assert by_sector[PortfolioSector.TECNOLOGIA] == 80.0
        assert by_sector[PortfolioSector.CONSUMO_BASICO] == 20.0
        # Equiponderada por cantidad daría 33/67 — exactamente lo contrario.
        assert result.weighting_basis == WeightingBasis.MARKET_VALUE

    async def test_una_cripto_va_a_su_sector_sin_preguntarle_al_proveedor(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        market = _FakeMarketData(prices={"BTC-USD": 50_000.0})
        service = _service(db_session_factory, market=market, fmp=_FakeFMP())

        result = await service.simulate(
            _request(
                100_000,
                _item(
                    "BTC-USD",
                    AllocationType.UNITS,
                    1,
                    asset_type=AssetType.CRYPTO,
                ),
            ),
            today=_TODAY,
        )

        assert result.items[0].sector == PortfolioSector.CRIPTO

    async def test_un_sector_desconocido_no_se_adivina(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        market = _FakeMarketData(prices={"XYZ": 100.0})
        service = _service(db_session_factory, market=market, fmp=_FakeFMP())

        result = await service.simulate(
            _request(1_000, _item("XYZ", AllocationType.UNITS, 5)), today=_TODAY
        )

        assert result.items[0].sector == PortfolioSector.SIN_CLASIFICAR
        assert result.availability == DataAvailability.PARTIAL

    async def test_una_posicion_sin_capital_no_agrega_un_sector_vacio(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        """Contarla con peso 0 agregaría a la torta un sector que no representa nada."""

        market = _FakeMarketData(prices={"NVDA": 100.0, "BRK": 700_000.0})
        fmp = _FakeFMP({"NVDA": "Technology", "BRK": "Financial Services"})
        service = _service(db_session_factory, market=market, fmp=fmp)

        result = await service.simulate(
            _request(
                1_000,
                _item("NVDA", AllocationType.AMOUNT_USD, 500),
                _item("BRK", AllocationType.AMOUNT_USD, 500),
            ),
            today=_TODAY,
        )

        sectors = [item.sector for item in result.sector_allocation]
        assert sectors == [PortfolioSector.TECNOLOGIA]

    def test_el_orden_es_estable_entre_corridas(self) -> None:
        """Un orden que baila haría que la UI reordene la torta sin que nada haya cambiado."""

        from app.schemas.portfolio_builder import PortfolioAllocationItem

        def _alloc(ticker: str, amount: float) -> PortfolioAllocationItem:
            return PortfolioAllocationItem(
                ticker=ticker,
                sector=PortfolioSector.TECNOLOGIA,
                sector_label="Tecnología",
                price_source=PriceSource.MARKET,
                units=1,
                invested_amount=amount,
                percentage_of_total=50.0,
            )

        items = [_alloc("AAA", 500.0), _alloc("BBB", 500.0)]
        sectors = {
            "AAA": PortfolioSector.TECNOLOGIA,
            "BBB": PortfolioSector.SERVICIOS_FINANCIEROS,
        }

        first = build_sector_amounts(items, sectors)
        second = build_sector_amounts(list(reversed(items)), sectors)
        assert [item.sector for item in first] == [item.sector for item in second]


# --- Concentración -------------------------------------------------------------------------------


class TestRiskScore:
    async def test_todo_en_un_sector_es_concentracion_maxima(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        market = _FakeMarketData(prices={"NVDA": 100.0, "AMD": 100.0})
        fmp = _FakeFMP({"NVDA": "Technology", "AMD": "Technology"})
        service = _service(db_session_factory, market=market, fmp=fmp)

        result = await service.simulate(
            _request(
                10_000,
                _item("NVDA", AllocationType.AMOUNT_USD, 5_000),
                _item("AMD", AllocationType.AMOUNT_USD, 5_000),
            ),
            today=_TODAY,
        )

        assert result.risk_score == RiskLevel.CRITICA
        assert result.herfindahl_index == 1.0
        assert result.top_sector == PortfolioSector.TECNOLOGIA
        assert any("mismo sector" in note for note in result.risk_notes)

    async def test_usa_la_misma_escala_que_la_auditoria(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        """La misma concentración no puede dar un veredicto distinto según la pantalla que la mire:
        el nivel sale de los umbrales compartidos en `portfolio_common`.
        """

        from app.services.portfolio_common import level_from_herfindahl

        market = _FakeMarketData(
            prices={"NVDA": 100.0, "KO": 100.0, "XOM": 100.0, "JPM": 100.0}
        )
        fmp = _FakeFMP(
            {
                "NVDA": "Technology",
                "KO": "Consumer Defensive",
                "XOM": "Energy",
                "JPM": "Financial Services",
            }
        )
        service = _service(db_session_factory, market=market, fmp=fmp)

        result = await service.simulate(
            _request(
                40_000,
                _item("NVDA", AllocationType.AMOUNT_USD, 10_000),
                _item("KO", AllocationType.AMOUNT_USD, 10_000),
                _item("XOM", AllocationType.AMOUNT_USD, 10_000),
                _item("JPM", AllocationType.AMOUNT_USD, 10_000),
            ),
            today=_TODAY,
        )

        assert result.herfindahl_index == pytest.approx(0.25, abs=0.001)
        assert result.risk_score == level_from_herfindahl(result.herfindahl_index or 0)

    async def test_una_cartera_corta_lo_dice_en_vez_de_bajarse_el_nivel(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        market = _FakeMarketData(prices={"NVDA": 100.0})
        fmp = _FakeFMP({"NVDA": "Technology"})
        service = _service(db_session_factory, market=market, fmp=fmp)

        result = await service.simulate(
            _request(1_000, _item("NVDA", AllocationType.AMOUNT_USD, 1_000)),
            today=_TODAY,
        )

        assert result.risk_score == RiskLevel.CRITICA
        assert any("todavía es corta" in note for note in result.risk_notes)

    async def test_sin_capital_asignado_no_hay_riesgo_que_medir(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        """`None` y no `BAJA`: no hay concentración baja donde no hay cartera."""

        service = _service(db_session_factory, market=None)

        result = await service.simulate(
            _request(1_000, _item("NVDA", AllocationType.PERCENTAGE, 100)),
            today=_TODAY,
        )

        assert result.risk_score is None
        assert result.herfindahl_index is None
        assert result.sector_allocation == []

    async def test_lo_sin_clasificar_declara_que_no_se_pudo_evaluar(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        market = _FakeMarketData(prices={"XYZ": 100.0})
        service = _service(db_session_factory, market=market, fmp=_FakeFMP())

        result = await service.simulate(
            _request(1_000, _item("XYZ", AllocationType.AMOUNT_USD, 1_000)),
            today=_TODAY,
        )

        assert any("no se pudo determinar" in note for note in result.risk_notes)


# --- Retorno a 1 año ------------------------------------------------------------------------------


class TestReturn1Y:
    async def test_mide_la_vela_de_hace_un_ano_contra_la_ultima(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        market = _FakeMarketData(
            prices={"NVDA": 200.0},
            histories={"NVDA": [(365, 100.0), (0, 200.0)]},
        )
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(10_000, _item("NVDA", AllocationType.AMOUNT_USD, 10_000)),
            today=_TODAY,
        )

        item = result.items[0]
        assert item.return_1y_pct == 100.0
        assert item.return_1y_from_date == date(2025, 8, 13)

    async def test_una_historia_corta_no_se_presenta_como_un_ano(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        """Un proveedor que devuelve un mes igual tiene una vela "más cercana a hace un año". Sin
        control de distancia, ese retorno mensual viajaría en un campo llamado `return_1y_pct`.
        """

        market = _FakeMarketData(
            prices={"NVDA": 200.0},
            histories={"NVDA": [(30, 180.0), (0, 200.0)]},
        )
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(10_000, _item("NVDA", AllocationType.AMOUNT_USD, 10_000)),
            today=_TODAY,
        )

        item = result.items[0]
        assert item.return_1y_pct is None
        assert item.return_1y_from_date is None
        assert item.note is not None
        assert "histórico" in item.note

    async def test_una_sola_vela_no_produce_un_retorno_de_cero(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        """Con una sola vela el retorno sería 0% por construcción y se leería como "no se movió"."""

        market = _FakeMarketData(
            prices={"NVDA": 200.0}, histories={"NVDA": [(365, 100.0)]}
        )
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(10_000, _item("NVDA", AllocationType.AMOUNT_USD, 10_000)),
            today=_TODAY,
        )

        assert result.items[0].return_1y_pct is None

    async def test_el_retorno_del_portafolio_se_pondera_por_capital(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        market = _FakeMarketData(
            prices={"NVDA": 100.0, "KO": 100.0},
            histories={
                "NVDA": [(365, 50.0), (0, 100.0)],  # +100%
                "KO": [(365, 100.0), (0, 100.0)],  # 0%
            },
        )
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(
                10_000,
                _item("NVDA", AllocationType.AMOUNT_USD, 7_500),
                _item("KO", AllocationType.AMOUNT_USD, 2_500),
            ),
            today=_TODAY,
        )

        # 100% * 0,75 + 0% * 0,25 = 75%. Un promedio simple daría 50%.
        assert result.portfolio_return_1y_pct == 75.0
        assert result.return_coverage_pct == 100.0

    async def test_una_cartera_medida_a_medias_declara_su_cobertura(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        """Promediar sobre el total equivaldría a asumir que lo no medible rindió 0%, que es una
        afirmación que nadie hizo.
        """

        market = _FakeMarketData(
            prices={"NVDA": 100.0, "KO": 100.0},
            histories={"NVDA": [(365, 50.0), (0, 100.0)]},
        )
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(
                10_000,
                _item("NVDA", AllocationType.AMOUNT_USD, 6_000),
                _item("KO", AllocationType.AMOUNT_USD, 4_000),
            ),
            today=_TODAY,
        )

        # El retorno es el de NVDA sola: se pondera sobre el capital MEDIBLE.
        assert result.portfolio_return_1y_pct == 100.0
        assert result.return_coverage_pct == 60.0

    async def test_sin_nada_medible_el_retorno_viaja_en_null(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        market = _FakeMarketData(prices={"NVDA": 100.0})
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(1_000, _item("NVDA", AllocationType.AMOUNT_USD, 1_000)),
            today=_TODAY,
        )

        assert result.portfolio_return_1y_pct is None
        assert result.return_coverage_pct == 0.0

    async def test_el_retorno_no_sale_del_precio_esperado(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        """Lo que hizo el activo el año pasado no cambia porque el usuario suponga otro precio."""

        market = _FakeMarketData(
            prices={"NVDA": 100.0},
            histories={"NVDA": [(365, 50.0), (0, 100.0)]},
        )
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(
                10_000,
                _item("NVDA", AllocationType.AMOUNT_USD, 10_000, custom_price=25.0),
            ),
            today=_TODAY,
        )

        # +100% sale de 50 -> 100 (mercado), no de 25 (esperado), que daría +300%.
        assert result.items[0].return_1y_pct == 100.0

    def test_el_ponderado_sin_posiciones_no_divide_por_cero(self) -> None:
        assert weighted_return_1y([]) == (None, 0.0)


# --- Degradación ----------------------------------------------------------------------------------


class TestDegradation:
    async def test_sin_proveedor_y_sin_precio_esperado_se_declara_el_motivo(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        service = _service(db_session_factory, market=None)

        result = await service.simulate(
            _request(1_000, _item("NVDA", AllocationType.PERCENTAGE, 100)),
            today=_TODAY,
        )

        assert result.availability == DataAvailability.UNAVAILABLE
        assert result.degradation_reason is not None
        assert "POLYGON_API_KEY" in result.degradation_reason
        item = result.items[0]
        assert item.price_source == PriceSource.UNAVAILABLE
        assert item.note is not None

    async def test_un_simbolo_sin_precio_no_tumba_los_demas(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        market = _FakeMarketData(prices={"NVDA": 100.0, "FANTASMA": None})
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(
                10_000,
                _item("NVDA", AllocationType.AMOUNT_USD, 5_000),
                _item("FANTASMA", AllocationType.AMOUNT_USD, 5_000),
            ),
            today=_TODAY,
        )

        assert result.availability == DataAvailability.PARTIAL
        assert result.items[0].units == 50
        assert result.items[1].units == 0
        # La posición sin precio NO entra en los porcentajes: NVDA se queda con el 100% de lo
        # invertido, que es la verdad de lo asignado.
        assert result.items[0].percentage_of_total == 100.0

    async def test_un_proveedor_que_lanza_no_tumba_la_simulacion(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        market = _FakeMarketData(raise_on_quotes=True)
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(
                1_000, _item("NVDA", AllocationType.PERCENTAGE, 100, custom_price=100.0)
            ),
            today=_TODAY,
        )

        # El precio esperado salva la posición aunque las cotizaciones hayan fallado enteras.
        assert result.items[0].units == 10

    async def test_un_historico_que_lanza_solo_pierde_el_retorno(
        self, db_session_factory: async_sessionmaker[AsyncSession]
    ) -> None:
        market = _FakeMarketData(prices={"NVDA": 100.0}, raise_on_history=True)
        service = _service(db_session_factory, market=market)

        result = await service.simulate(
            _request(1_000, _item("NVDA", AllocationType.AMOUNT_USD, 1_000)),
            today=_TODAY,
        )

        assert result.items[0].units == 10
        assert result.items[0].return_1y_pct is None


# --- Endpoint --------------------------------------------------------------------------------------


class TestEndpoint:
    async def test_exige_autenticacion(self, client: httpx.AsyncClient) -> None:
        response = await client.post(
            "/api/v1/portfolio-builder/simulate",
            json={
                "total_budget": 1_000,
                "items": [
                    {
                        "ticker": "NVDA",
                        "allocation_type": "PERCENTAGE",
                        "allocation_value": 100,
                    }
                ],
            },
        )
        assert response.status_code == 401

    async def test_sin_credenciales_responde_200_degradado(
        self, client: httpx.AsyncClient
    ) -> None:
        """Un 503 obligaría al cliente a traducir "no configurado" a un aviso, que es exactamente lo
        que la respuesta ya trae.
        """

        headers = await _auth(client, "pb-degraded@example.com")

        response = await client.post(
            "/api/v1/portfolio-builder/simulate",
            json={
                "total_budget": 1_000,
                "items": [
                    {
                        "ticker": "NVDA",
                        "allocation_type": "PERCENTAGE",
                        "allocation_value": 100,
                    }
                ],
            },
            headers=headers,
        )

        body = response.json()
        assert response.status_code == 200
        assert body["availability"] == "UNAVAILABLE"
        assert body["degradation_reason"] is not None

    async def test_una_cartera_con_precios_esperados_responde_completa(
        self, client: httpx.AsyncClient
    ) -> None:
        headers = await _auth(client, "pb-custom@example.com")

        response = await client.post(
            "/api/v1/portfolio-builder/simulate",
            json={
                "total_budget": 10_000,
                "items": [
                    {
                        "ticker": "NVDA",
                        "allocation_type": "PERCENTAGE",
                        "allocation_value": 50,
                        "custom_price": 250,
                    },
                    {
                        "ticker": "KO",
                        "allocation_type": "UNITS",
                        "allocation_value": 40,
                        "custom_price": 50,
                    },
                ],
            },
            headers=headers,
        )

        body = response.json()
        assert response.status_code == 200
        assert [item["units"] for item in body["items"]] == [20, 40]
        # Sin FMP en el entorno de test los sectores no se resuelven: el reparto está completo y lo
        # único degradado es la clasificación, que viaja con su motivo.
        assert body["availability"] == "PARTIAL"
        assert body["allocated_amount"] == 7_000.0
        assert body["cash_unallocated"] == 3_000.0
        assert body["weighting_basis"] == "MARKET_VALUE"

    async def test_el_tipo_de_asignacion_viaja_como_string(
        self, client: httpx.AsyncClient
    ) -> None:
        """JSON no tiene tipo nativo para Enum: el cliente manda `"PERCENTAGE"`, no el enum."""

        headers = await _auth(client, "pb-enum@example.com")

        response = await client.post(
            "/api/v1/portfolio-builder/simulate",
            json={
                "total_budget": 1_000,
                "items": [
                    {
                        "ticker": "BTC-USD",
                        "asset_type": "CRYPTO",
                        "allocation_type": "AMOUNT_USD",
                        "allocation_value": 500,
                        "custom_price": 100,
                    }
                ],
            },
            headers=headers,
        )

        body = response.json()
        assert response.status_code == 200
        assert body["items"][0]["sector"] == "CRIPTO"
        assert body["items"][0]["units"] == 5

    async def test_un_monto_redondo_viaja_como_entero(
        self, client: httpx.AsyncClient
    ) -> None:
        headers = await _auth(client, "pb-int@example.com")

        response = await client.post(
            "/api/v1/portfolio-builder/simulate",
            json={
                "total_budget": 1_000,
                "items": [
                    {
                        "ticker": "NVDA",
                        "allocation_type": "UNITS",
                        "allocation_value": 5,
                        "custom_price": 100,
                    }
                ],
            },
            headers=headers,
        )

        assert response.status_code == 200
        assert response.json()["items"][0]["invested_amount"] == 500.0

    async def test_una_lista_vacia_es_422(self, client: httpx.AsyncClient) -> None:
        headers = await _auth(client, "pb-empty@example.com")

        response = await client.post(
            "/api/v1/portfolio-builder/simulate",
            json={"total_budget": 1_000, "items": []},
            headers=headers,
        )
        assert response.status_code == 422

    async def test_un_presupuesto_no_positivo_es_422(
        self, client: httpx.AsyncClient
    ) -> None:
        headers = await _auth(client, "pb-budget@example.com")

        response = await client.post(
            "/api/v1/portfolio-builder/simulate",
            json={
                "total_budget": 0,
                "items": [
                    {
                        "ticker": "NVDA",
                        "allocation_type": "UNITS",
                        "allocation_value": 1,
                    }
                ],
            },
            headers=headers,
        )
        assert response.status_code == 422

    async def test_un_precio_esperado_negativo_es_422(
        self, client: httpx.AsyncClient
    ) -> None:
        headers = await _auth(client, "pb-negprice@example.com")

        response = await client.post(
            "/api/v1/portfolio-builder/simulate",
            json={
                "total_budget": 1_000,
                "items": [
                    {
                        "ticker": "NVDA",
                        "allocation_type": "UNITS",
                        "allocation_value": 1,
                        "custom_price": -10,
                    }
                ],
            },
            headers=headers,
        )
        assert response.status_code == 422

    async def test_un_nan_en_el_presupuesto_es_422(
        self, client: httpx.AsyncClient
    ) -> None:
        headers = await _auth(client, "pb-nan@example.com")

        response = await client.post(
            "/api/v1/portfolio-builder/simulate",
            content=(
                '{"total_budget": NaN, "items": [{"ticker": "NVDA", '
                '"allocation_type": "UNITS", "allocation_value": 1}]}'
            ),
            headers={**headers, "content-type": "application/json"},
        )
        assert response.status_code == 422

    async def test_demasiadas_posiciones_es_422(
        self, client: httpx.AsyncClient
    ) -> None:
        headers = await _auth(client, "pb-many@example.com")

        response = await client.post(
            "/api/v1/portfolio-builder/simulate",
            json={
                "total_budget": 1_000,
                "items": [
                    {
                        "ticker": f"T{index}",
                        "allocation_type": "UNITS",
                        "allocation_value": 1,
                    }
                    for index in range(40)
                ],
            },
            headers=headers,
        )
        assert response.status_code == 422

    async def test_un_campo_desconocido_es_422(self, client: httpx.AsyncClient) -> None:
        headers = await _auth(client, "pb-extra@example.com")

        response = await client.post(
            "/api/v1/portfolio-builder/simulate",
            json={
                "total_budget": 1_000,
                "apalancamiento": 3,
                "items": [
                    {
                        "ticker": "NVDA",
                        "allocation_type": "UNITS",
                        "allocation_value": 1,
                    }
                ],
            },
            headers=headers,
        )
        assert response.status_code == 422
