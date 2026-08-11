"""Tests del Laboratorio Financiero: `/api/v1/ai-lab/*`.

Los contratos que este módulo promete y que son fáciles de romper sin darse cuenta:

  1. **Ningún número pasa por el modelo.** Los márgenes, el DuPont, las banderas, la proyección y el
     precio implícito salen de funciones puras. Si mañana alguien le pidiera al LLM un campo
     numérico, ese número competiría con el calculado — y alguna pantalla mostraría el del modelo.
  2. **Un cociente sobre una base ínfima no se calcula.** Un margen de 4.000% sobre ingresos de cien
     mil dólares existe y es basura; el piso es lo único que lo evita.
  3. **El precio implícito requiere un EPS base positivo.** Sobre una pérdida, un múltiplo P/E no
     tiene interpretación: viaja en `null` con su motivo, nunca en 0.
  4. **El evento en texto no mueve ningún número.** Cuantificar un rumor sería pedirle al modelo un
     coeficiente que nadie midió, y la respuesta lo declara.
  5. **Los supuestos del modelo viajan con el resultado.** Una proyección sin ellos tiene la
     autoridad de un pronóstico y la solidez de una cuenta al margen.
  6. **Sin Gemini el análisis conserva TODOS sus números.** Lo único que falta es la prosa, y su
     motivo va en un campo aparte del general — un solo campo obligaría a elegir cuál contar.
"""

from __future__ import annotations

from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

import httpx
import pytest

from app.main import app
from app.schemas.ai_lab import (
    ConversationRole,
    ConversationTurn,
    FinancialAnalysisRequest,
    FlagKind,
    FlagSeverity,
    NarrativeSource,
    ScenarioCase,
    ScenarioSimulationRequest,
    ScenarioVariables,
    StatementPeriod,
    ValuationBasis,
)
from app.schemas.intelligence import DataAvailability
from app.services.ai_lab_service import (
    REASON_FMP_FAILED,
    REASON_GEMINI_FAILED,
    REASON_NO_BASELINE,
    REASON_NO_FMP,
    REASON_NO_GEMINI,
    REASON_NO_STATEMENTS,
    AiLabService,
    build_analysis_prompt,
    build_balance_block,
    build_baseline,
    build_cash_flow_block,
    build_dupont,
    build_income_block,
    build_model_assumptions,
    build_scenario_prompt,
    build_sensitivity,
    change_pct,
    es_millions,
    es_number,
    evaluate_flags,
    project_scenario,
    safe_pct,
    shift_variables,
    valuation_note,
)
from src.ingestion.schemas_raw import FinancialStatements, GeminiGenerationResult
from src.validation.domain_models import DataStatus, FinancialMetrics, MetricValue

# --- Dobles ------------------------------------------------------------------------------------


class _FakeFMP:
    def __init__(
        self,
        *,
        statements: FinancialStatements | None = None,
        status: DataStatus = DataStatus.OK,
        metrics: FinancialMetrics | None = None,
        raise_on_statements: bool = False,
    ) -> None:
        self._statements = statements
        self._status = status
        self._metrics = metrics
        self._raise = raise_on_statements

        self.statement_calls: list[dict[str, Any]] = []
        self.metrics_calls = 0

    async def get_financial_statements(
        self, ticker: str, *, period: str = "annual", limit: int = 5
    ) -> tuple[FinancialStatements, DataStatus]:
        self.statement_calls.append(
            {"ticker": ticker, "period": period, "limit": limit}
        )
        if self._raise:
            raise RuntimeError("bug inesperado del cliente")
        empty = FinancialStatements(
            ticker=ticker, period=period, income=[], balance=[], cash_flow=[]
        )
        if self._status != DataStatus.OK:
            return empty, self._status
        return self._statements or empty, DataStatus.OK

    async def get_financial_metrics(self, ticker: str) -> FinancialMetrics:
        self.metrics_calls += 1
        return self._metrics or _metrics()


class _FakeGemini:
    def __init__(
        self,
        *,
        raw_json_text: str | None = '{"narrative": "Lectura del analista."}',
        status: DataStatus = DataStatus.OK,
    ) -> None:
        self._raw = raw_json_text
        self._status = status
        self.calls = 0
        self.prompts: list[str] = []
        self.system_instructions: list[str] = []

    async def generate_structured_json(
        self,
        *,
        system_instruction: str,
        user_content: str,
        response_schema: dict[str, Any],
        temperature: float = 0.2,
        model: str | None = None,
    ) -> GeminiGenerationResult:
        self.calls += 1
        self.prompts.append(user_content)
        self.system_instructions.append(system_instruction)
        return GeminiGenerationResult(
            status=self._status,
            raw_json_text=self._raw,
            finish_reason="STOP" if self._status is DataStatus.OK else None,
            model="fake-gemini",
            generated_at=datetime(2026, 8, 10, 12, tzinfo=timezone.utc),
        )


def _service(**kwargs: Any) -> AiLabService:
    return AiLabService(
        analysis_prompt="Prompt de análisis.",
        scenario_prompt="Prompt de escenario.",
        **kwargs,
    )


# --- Fixtures ----------------------------------------------------------------------------------


def _income_row(
    *,
    date: str = "2026-01-31",
    period: str = "FY",
    revenue: float | None = 100_000_000_000.0,
    cost_of_revenue: float = 40_000_000_000.0,
    gross_profit: float = 60_000_000_000.0,
    operating_income: float | None = 50_000_000_000.0,
    ebitda: float | None = None,
    depreciation: float | None = 5_000_000_000.0,
    interest: float | None = 1_000_000_000.0,
    pretax: float | None = 49_000_000_000.0,
    tax: float | None = 9_800_000_000.0,
    net_income: float | None = 39_200_000_000.0,
    eps: float | None = 1.60,
    shares: float | None = 24_500_000_000.0,
) -> dict[str, Any]:
    row: dict[str, Any] = {
        "date": date,
        "period": period,
        "revenue": revenue,
        "costOfRevenue": cost_of_revenue,
        "grossProfit": gross_profit,
        "operatingIncome": operating_income,
        "depreciationAndAmortization": depreciation,
        "interestExpense": interest,
        "incomeBeforeTax": pretax,
        "incomeTaxExpense": tax,
        "netIncome": net_income,
        "epsDiluted": eps,
        "weightedAverageShsOutDil": shares,
    }
    if ebitda is not None:
        row["ebitda"] = ebitda
    return row


def _balance_row(
    *,
    date: str = "2026-01-31",
    period: str = "FY",
    total_assets: float | None = 120_000_000_000.0,
    current_assets: float | None = 60_000_000_000.0,
    cash: float | None = 30_000_000_000.0,
    total_liabilities: float | None = 40_000_000_000.0,
    current_liabilities: float | None = 20_000_000_000.0,
    total_debt: float | None = 10_000_000_000.0,
    equity: float | None = 80_000_000_000.0,
) -> dict[str, Any]:
    return {
        "date": date,
        "period": period,
        "totalAssets": total_assets,
        "totalCurrentAssets": current_assets,
        "cashAndCashEquivalents": cash,
        "totalLiabilities": total_liabilities,
        "totalCurrentLiabilities": current_liabilities,
        "totalDebt": total_debt,
        "totalStockholdersEquity": equity,
    }


def _cash_row(
    *,
    date: str = "2026-01-31",
    period: str = "FY",
    operating: float | None = 45_000_000_000.0,
    capex: float | None = -5_000_000_000.0,
    fcf: float | None = 40_000_000_000.0,
) -> dict[str, Any]:
    row: dict[str, Any] = {
        "date": date,
        "period": period,
        "operatingCashFlow": operating,
        "capitalExpenditure": capex,
    }
    if fcf is not None:
        row["freeCashFlow"] = fcf
    return row


def _statements(
    *,
    income: list[dict[str, Any]] | None = None,
    balance: list[dict[str, Any]] | None = None,
    cash_flow: list[dict[str, Any]] | None = None,
    period: str = "annual",
) -> FinancialStatements:
    return FinancialStatements(
        ticker="NVDA",
        period=period,
        income=income if income is not None else [_income_row()],
        balance=balance if balance is not None else [_balance_row()],
        cash_flow=cash_flow if cash_flow is not None else [_cash_row()],
    )


def _metric(value: float | None) -> MetricValue:
    # `MetricValue.value` es `Decimal`, no float: el contrato de ingesta usa decimales para no
    # arrastrar el error binario de los flotantes en cifras contables.
    return MetricValue(
        value=None if value is None else Decimal(str(value)),
        status=DataStatus.OK if value is not None else DataStatus.NO_DISPONIBLE,
        source="test",
        as_of=datetime(2026, 8, 10, tzinfo=timezone.utc),
    )


def _metrics(
    *,
    market_cap: float | None = 2_450_000_000_000.0,
    shares: float | None = 24_500_000_000.0,
) -> FinancialMetrics:
    return FinancialMetrics(
        ticker="NVDA",
        fetched_at=datetime(2026, 8, 10, tzinfo=timezone.utc),
        price_earnings_ratio=_metric(62.5),
        price_earnings_growth_ratio=_metric(None),
        debt_to_ebitda=_metric(None),
        debt_to_equity=_metric(None),
        free_cash_flow=_metric(None),
        free_cash_flow_yield_pct=_metric(None),
        revenue_growth_yoy_pct=_metric(None),
        gross_margin_pct=_metric(None),
        operating_margin_pct=_metric(None),
        return_on_equity_pct=_metric(None),
        current_ratio=_metric(None),
        shares_outstanding=_metric(shares),
        market_cap=_metric(market_cap),
        fundamentals_period="TTM",
        fundamentals_report_date=None,
    )


async def _auth(client: httpx.AsyncClient, email: str) -> dict[str, str]:
    await client.post(
        "/api/v1/auth/register", json={"email": email, "password": "supersecreta1"}
    )
    login = await client.post(
        "/api/v1/auth/login", json={"email": email, "password": "supersecreta1"}
    )
    return {"Authorization": f"Bearer {login.json()['access_token']}"}


# --- Utilidades numéricas ----------------------------------------------------------------------


class TestSafeMath:
    def test_un_denominador_infimo_no_produce_cociente(self) -> None:
        """El modo de falla que este piso existe para evitar: un margen de 4.000% calculado sobre
        ingresos de cien mil dólares en un trimestre de transición. El número existiría y sería
        basura.
        """

        assert safe_pct(4_000_000.0, 100_000.0) is None
        assert safe_pct(40_000_000.0, 100_000_000.0) == pytest.approx(40.0)

    def test_la_variacion_requiere_una_base_positiva(self) -> None:
        """Pasar de −100 a −50 no es "+50%": la variación porcentual sobre una base negativa cambia
        de signo sin que el negocio haya mejorado ni empeorado.
        """

        assert change_pct(-50.0, -100.0) is None
        assert change_pct(120.0, 100.0) == pytest.approx(20.0)
        assert change_pct(120.0, 0.0) is None


# --- Bloques contables -------------------------------------------------------------------------


class TestSpanishNumbers:
    def test_da_vuelta_los_separadores_sin_pisarse(self) -> None:
        """El bug clásico de reemplazar en cadena: convertir "32,900.00" a "32.900,00" en dos pasos
        directos deja puntos donde iban comas.
        """

        assert es_number(32_900.5) == "32.900,50"
        assert es_number(1_234_567.891, decimals=1) == "1.234.567,9"
        assert es_number(3.6743, decimals=2) == "3,67"
        assert es_number(-5.0, decimals=0) == "-5"

    def test_los_montos_van_en_millones(self) -> None:
        assert es_millions(32_900_000_000.0) == "US$ 32.900 M"


class TestIncomeBlock:
    def test_calcula_los_cuatro_margenes(self) -> None:
        block = build_income_block(_income_row())

        assert block.gross_margin_pct == pytest.approx(60.0)
        assert block.operating_margin_pct == pytest.approx(50.0)
        assert block.net_margin_pct == pytest.approx(39.2)
        assert block.effective_tax_rate_pct == pytest.approx(20.0)

    def test_el_ebitda_publicado_no_se_recalcula(self) -> None:
        block = build_income_block(_income_row(ebitda=56_000_000_000.0))

        assert block.ebitda == pytest.approx(56_000_000_000.0)
        assert block.ebitda_is_derived is False

    def test_sin_ebitda_publicado_se_reconstruye_y_se_declara(self) -> None:
        """Un EBITDA reconstruido puede no coincidir con el que la empresa informa (que suele excluir
        cargos no recurrentes): presentarlos como la misma cosa le atribuiría a la empresa un número
        que no dijo.
        """

        block = build_income_block(_income_row(ebitda=None))

        assert block.ebitda == pytest.approx(55_000_000_000.0)
        assert block.ebitda_is_derived is True

    def test_el_gasto_de_intereses_se_normaliza_a_positivo(self) -> None:
        """Algunos endpoints lo mandan negativo (es un egreso) y otros positivo. Sin normalizar, la
        cobertura de intereses saldría con el signo dado vuelta y una empresa sólida aparecería en
        rojo.
        """

        negative = build_income_block(_income_row(interest=-1_000_000_000.0))
        positive = build_income_block(_income_row(interest=1_000_000_000.0))

        assert negative.interest_expense == positive.interest_expense

    def test_una_perdida_no_produce_tasa_efectiva(self) -> None:
        # El cociente impuesto/resultado sobre una pérdida da un número sin interpretación contable.
        block = build_income_block(
            _income_row(pretax=-5_000_000_000.0, tax=100_000_000.0)
        )
        assert block.effective_tax_rate_pct is None

    def test_una_linea_ausente_queda_en_none_y_no_en_cero(self) -> None:
        block = build_income_block(_income_row(revenue=None, operating_income=None))

        assert block.revenue is None
        assert block.gross_margin_pct is None

    def test_un_booleano_del_proveedor_no_entra_como_uno(self) -> None:
        # `isinstance(True, int)` es verdadero en Python: sin el descarte explícito, un `True`
        # colado en una línea contable entraría como 1.
        block = build_income_block({**_income_row(), "revenue": True})
        assert block.revenue is None

    def test_un_nan_del_json_se_descarta(self) -> None:
        block = build_income_block({**_income_row(), "netIncome": float("nan")})
        assert block.net_income is None


class TestBalanceBlock:
    def test_calcula_liquidez_apalancamiento_y_deuda_neta(self) -> None:
        block = build_balance_block(_balance_row())

        assert block.current_ratio == pytest.approx(3.0)
        assert block.debt_to_equity == pytest.approx(0.125)
        # Caja neta: la deuda neta negativa es un dato, no un error.
        assert block.net_debt == pytest.approx(-20_000_000_000.0)

    def test_la_deuda_total_se_reconstruye_sumando_plazos(self) -> None:
        row = {
            **_balance_row(total_debt=None),
            "shortTermDebt": 2_000_000_000.0,
            "longTermDebt": 8_000_000_000.0,
        }
        assert build_balance_block(row).total_debt == pytest.approx(10_000_000_000.0)

    def test_con_patrimonio_negativo_no_se_calcula_el_apalancamiento(self) -> None:
        """Con patrimonio negativo el ratio da un número negativo que se leería como "poca deuda",
        que es lo contrario de lo que pasa.
        """

        block = build_balance_block(_balance_row(equity=-5_000_000_000.0))
        assert block.debt_to_equity is None


class TestCashFlowBlock:
    def test_la_conversion_cruza_los_dos_estados(self) -> None:
        block = build_cash_flow_block(
            _cash_row(), revenue=100_000_000_000.0, net_income=39_200_000_000.0
        )

        assert block.fcf_conversion_pct == pytest.approx(102.04, abs=0.01)
        assert block.capex_to_revenue_pct == pytest.approx(5.0)

    def test_sin_fcf_publicado_se_deriva_de_la_caja_operativa(self) -> None:
        block = build_cash_flow_block(_cash_row(fcf=None))

        assert block.free_cash_flow == pytest.approx(40_000_000_000.0)
        assert block.free_cash_flow_is_derived is True

    def test_con_perdida_no_se_mide_la_conversion(self) -> None:
        # Con pérdidas el cociente invierte el signo y una empresa que quema caja aparecería con
        # "conversión positiva".
        block = build_cash_flow_block(_cash_row(), net_income=-1_000_000_000.0)
        assert block.fcf_conversion_pct is None


class TestDupont:
    def test_descompone_el_roe_en_sus_tres_factores(self) -> None:
        dupont = build_dupont(
            build_income_block(_income_row()), build_balance_block(_balance_row())
        )

        assert dupont.net_margin_pct == pytest.approx(39.2)
        assert dupont.asset_turnover == pytest.approx(100 / 120, abs=0.001)
        assert dupont.equity_multiplier == pytest.approx(1.5)
        # El producto de los tres factores es el ROE: 39.200 de ganancia sobre 80.000 de patrimonio.
        assert dupont.roe_pct == pytest.approx(49.0, abs=0.1)

    def test_el_producto_es_el_roe_sea_cual_sea_el_activo(self) -> None:
        """La identidad es algebraica: los cocientes se cancelan. Un activo distinto reparte el ROE
        entre rotación y apalancamiento sin cambiar el total — y por eso el módulo NO publica un flag
        de "reconciliación": sería un chequeo que no puede fallar.
        """

        inflated = build_dupont(
            build_income_block(_income_row()),
            build_balance_block(_balance_row(total_assets=200_000_000_000.0)),
        )

        assert inflated.asset_turnover == pytest.approx(0.5)
        assert inflated.equity_multiplier == pytest.approx(2.5)
        assert inflated.roe_pct == pytest.approx(49.0, abs=0.1)

    def test_con_patrimonio_negativo_no_hay_producto_parcial(self) -> None:
        """Un ROE parcial (con dos de los tres factores) sería peor que ninguno."""

        dupont = build_dupont(
            build_income_block(_income_row()),
            build_balance_block(_balance_row(equity=-1_000_000_000.0)),
        )

        assert dupont.equity_multiplier is None
        assert dupont.roe_pct is None

    def test_sin_balance_el_bloque_queda_vacio_sin_explotar(self) -> None:
        dupont = build_dupont(build_income_block(_income_row()), None)
        assert dupont.is_complete is False
        assert dupont.roe_pct is None


# --- Banderas ----------------------------------------------------------------------------------


class TestFlags:
    def _codes(self, **kwargs: Any) -> list[str]:
        income = [
            build_income_block(row) for row in kwargs.get("income", [_income_row()])
        ]
        balances = [
            build_balance_block(row) for row in kwargs.get("balance", [_balance_row()])
        ]
        cash = [
            build_cash_flow_block(
                row,
                revenue=income[0].revenue if income else None,
                net_income=income[0].net_income if income else None,
            )
            for row in kwargs.get("cash_flow", [_cash_row()])
        ]
        return [flag.code for flag in evaluate_flags(income, balances, cash)]

    def test_una_empresa_sana_solo_dispara_banderas_verdes(self) -> None:
        flags = evaluate_flags(
            [build_income_block(_income_row())],
            [build_balance_block(_balance_row())],
            [
                build_cash_flow_block(
                    _cash_row(), revenue=100_000_000_000.0, net_income=39_200_000_000.0
                )
            ],
        )

        assert flags
        assert all(flag.kind is FlagKind.GREEN for flag in flags)
        assert "NET_CASH_POSITION" in {flag.code for flag in flags}

    def test_el_apalancamiento_alto_dispara_la_bandera_con_su_umbral(self) -> None:
        flags = evaluate_flags(
            [build_income_block(_income_row())],
            [
                build_balance_block(
                    _balance_row(total_debt=400_000_000_000.0, equity=80_000_000_000.0)
                )
            ],
            [],
        )
        critical = next(
            flag for flag in flags if flag.code == "DEBT_TO_EQUITY_CRITICAL"
        )

        assert critical.kind is FlagKind.RED
        assert critical.severity is FlagSeverity.CRITICAL
        # El umbral viaja EN la bandera: "apalancamiento alto" sin el número es una opinión.
        assert critical.threshold == pytest.approx(4.0)
        # El detalle es prosa en castellano que se muestra tal cual: coma decimal y punto de miles.
        assert "5,00x" in critical.detail

    def test_la_cobertura_de_intereses_critica_se_detecta(self) -> None:
        codes = self._codes(
            income=[
                _income_row(operating_income=1_000_000_000.0, interest=900_000_000.0)
            ]
        )
        assert "INTEREST_COVERAGE_CRITICAL" in codes

    def test_el_patrimonio_negativo_es_critico(self) -> None:
        codes = self._codes(balance=[_balance_row(equity=-1_000_000_000.0)])
        assert "NEGATIVE_EQUITY" in codes

    def test_la_ganancia_que_no_se_convierte_en_caja_se_marca(self) -> None:
        codes = self._codes(
            cash_flow=[
                _cash_row(
                    operating=5_000_000_000.0,
                    capex=-1_000_000_000.0,
                    fcf=4_000_000_000.0,
                )
            ]
        )
        assert "WEAK_FCF_CONVERSION" in codes

    def test_el_fcf_negativo_se_marca(self) -> None:
        codes = self._codes(cash_flow=[_cash_row(fcf=-2_000_000_000.0)])
        assert "NEGATIVE_FREE_CASH_FLOW" in codes

    def test_el_crecimiento_necesita_dos_periodos(self) -> None:
        one_period = self._codes()
        assert "REVENUE_GROWTH_STRONG" not in one_period

        two_periods = self._codes(
            income=[
                _income_row(revenue=100_000_000_000.0),
                _income_row(date="2025-01-31", revenue=70_000_000_000.0),
            ]
        )
        assert "REVENUE_GROWTH_STRONG" in two_periods

    def test_la_caida_de_ingresos_se_marca(self) -> None:
        codes = self._codes(
            income=[
                _income_row(revenue=70_000_000_000.0),
                _income_row(date="2025-01-31", revenue=100_000_000_000.0),
            ]
        )
        assert "REVENUE_DECLINE" in codes

    def test_las_banderas_salen_ordenadas_por_gravedad(self) -> None:
        """Sin un orden fijo, dos pantallas mostrarían la misma empresa con distinta primera
        impresión.
        """

        flags = evaluate_flags(
            [build_income_block(_income_row(net_income=-1_000_000_000.0))],
            [build_balance_block(_balance_row())],
            [
                build_cash_flow_block(
                    _cash_row(), revenue=100_000_000_000.0, net_income=39_200_000_000.0
                )
            ],
        )

        severities = [flag.severity for flag in flags]
        assert severities[0] is FlagSeverity.CRITICAL
        assert severities == sorted(
            severities,
            key=lambda item: {
                FlagSeverity.CRITICAL: 0,
                FlagSeverity.WARNING: 1,
                FlagSeverity.INFO: 2,
            }[item],
        )

    def test_sin_estados_no_hay_banderas_inventadas(self) -> None:
        assert evaluate_flags([], [], []) == []


# --- Simulador: base ---------------------------------------------------------------------------


class TestBaseline:
    def _baseline(self, **kwargs: Any) -> Any:
        income = build_income_block(kwargs.get("income_row", _income_row()))
        balance = build_balance_block(kwargs.get("balance_row", _balance_row()))
        cash = build_cash_flow_block(_cash_row(), net_income=income.net_income)
        return build_baseline(
            income,
            balance,
            cash,
            kwargs.get("metrics", _metrics()),
            period=StatementPeriod.ANNUAL,
        )

    def test_deriva_precio_y_multiplo_del_mismo_eps_que_va_a_proyectar(self) -> None:
        """La consistencia interna es la que hace que la variación del precio implícito signifique
        algo: mezclar un P/E publicado (calculado sobre otro EPS) con el EPS de este balance daría
        una variación que no se corresponde con ninguno de los dos.
        """

        baseline = self._baseline()

        assert baseline.reference_price == pytest.approx(100.0)
        assert baseline.eps == pytest.approx(1.60)
        assert baseline.price_earnings_multiple == pytest.approx(62.5)

    def test_la_tasa_implicita_de_la_deuda_se_deduce_no_se_supone(self) -> None:
        baseline = self._baseline()
        # 1.000 M de intereses sobre 10.000 M de deuda = 10%.
        assert baseline.implied_interest_rate_pct == pytest.approx(10.0)

    def test_una_tasa_efectiva_absurda_se_descarta(self) -> None:
        """Un período con quebrantos o un crédito fiscal extraordinario puede dar una tasa del 300%:
        proyectar con ella multiplica el error.
        """

        baseline = self._baseline(
            income_row=_income_row(pretax=1_000_000_000.0, tax=3_000_000_000.0)
        )
        assert baseline.effective_tax_rate_pct is None

    def test_sin_capitalizacion_no_hay_precio_de_referencia(self) -> None:
        baseline = self._baseline(metrics=_metrics(market_cap=None))

        assert baseline.reference_price is None
        assert baseline.price_earnings_multiple is None

    def test_sin_ganancia_operativa_no_hay_multiplo(self) -> None:
        """El múltiplo se calcula contra el punto cero del MODELO, así que lo que lo anula es que la
        cascada no genere ganancia — no que la empresa haya reportado una pérdida.
        """

        baseline = self._baseline(
            income_row=_income_row(operating_income=-8_000_000_000.0, ebitda=None)
        )

        assert baseline.model_eps is not None
        assert baseline.model_eps < 0
        assert baseline.price_earnings_multiple is None

    def test_una_perdida_reportada_con_operativo_positivo_sigue_teniendo_multiplo(
        self,
    ) -> None:
        """Una pérdida contable por un cargo extraordinario no impide simular: la cascada parte del
        EBITDA, que sigue siendo positivo. La diferencia entre el EPS reportado y el del modelo se
        declara en los supuestos.
        """

        baseline = self._baseline(
            income_row=_income_row(eps=-0.50, net_income=-12_000_000_000.0)
        )

        assert baseline.eps == pytest.approx(-0.50)
        assert baseline.model_eps is not None and baseline.model_eps > 0
        assert baseline.price_earnings_multiple is not None


# --- Simulador: proyección ---------------------------------------------------------------------


def _baseline_fixture() -> Any:
    income = build_income_block(_income_row())
    balance = build_balance_block(_balance_row())
    cash = build_cash_flow_block(_cash_row(), net_income=income.net_income)
    return build_baseline(
        income, balance, cash, _metrics(), period=StatementPeriod.ANNUAL
    )


class TestProjection:
    def test_un_escenario_sin_variables_no_mueve_nada(self) -> None:
        """El defecto que la referencia del modelo existe para arreglar.

        Midiendo contra el resultado REPORTADO, un escenario vacío daba −1,3% de EPS y de precio: la
        cascada modela EBITDA → amortizaciones → intereses → impuestos y no reproduce los resultados
        no operativos de la empresa, así que esa diferencia era el error de aproximación del modelo
        presentándose como el efecto de algo. Un usuario lo lee como "el precio baja".
        """

        baseline = _baseline_fixture()
        projection = project_scenario(baseline, ScenarioVariables())

        assert projection.revenue_change_pct == pytest.approx(0.0)
        assert projection.ebitda_change_pct == pytest.approx(0.0)
        assert projection.eps_change_pct == pytest.approx(0.0)
        assert projection.free_cash_flow_change_pct == pytest.approx(0.0)
        assert projection.implied_price == pytest.approx(baseline.reference_price or 0)
        assert projection.implied_price_change_pct == pytest.approx(0.0)

    def test_con_un_estado_que_cierra_el_punto_cero_coincide_con_lo_reportado(
        self,
    ) -> None:
        """Cuando el estado no tiene líneas no operativas, la cascada reproduce el resultado y los dos
        EPS coinciden. Es la comprobación de que el modelo no introduce un sesgo propio.
        """

        baseline = _baseline_fixture()

        assert baseline.eps == pytest.approx(1.60)
        assert baseline.model_eps == pytest.approx(1.60)
        # El múltiplo se calcula SIEMPRE contra el punto cero, coincidan o no.
        assert baseline.price_earnings_multiple == pytest.approx(
            (baseline.reference_price or 0) / (baseline.model_eps or 1)
        )

    def test_con_resultados_no_operativos_los_dos_eps_difieren_y_se_publican(
        self,
    ) -> None:
        """Una empresa real tiene resultados no operativos: ahí el punto cero del modelo se separa del
        EPS reportado, y los dos viajan porque cumplen funciones distintas.
        """

        # Pretax reportado 2.000 M por encima de operativo − intereses: hay ingresos no operativos que
        # la cascada no modela.
        income = build_income_block(
            _income_row(pretax=51_000_000_000.0, net_income=40_800_000_000.0, eps=1.67)
        )
        baseline = build_baseline(
            income,
            build_balance_block(_balance_row()),
            None,
            _metrics(),
            period=StatementPeriod.ANNUAL,
        )

        assert baseline.eps is not None
        assert baseline.eps == pytest.approx(1.67)
        assert baseline.model_eps is not None
        assert baseline.model_eps < baseline.eps
        # Y aun así, un escenario vacío no muestra variación: la referencia es el punto cero.
        assert project_scenario(baseline, ScenarioVariables()).eps_change_pct == (
            pytest.approx(0.0)
        )

    def test_los_supuestos_declaran_la_diferencia_entre_los_dos_eps(self) -> None:
        assumptions = build_model_assumptions(_baseline_fixture(), ScenarioVariables())
        assert any("punto cero del modelo" in item for item in assumptions)

    def test_el_crecimiento_de_ingresos_se_propaga_por_la_cascada(self) -> None:
        baseline = _baseline_fixture()
        projection = project_scenario(
            baseline, ScenarioVariables(revenue_growth_pct=10.0)
        )

        assert projection.revenue == pytest.approx(110_000_000_000.0)
        # Margen EBITDA base 55% (50.000 operativo + 5.000 D&A sobre 100.000 de ingresos).
        assert projection.ebitda == pytest.approx(60_500_000_000.0)
        assert projection.revenue_change_pct == pytest.approx(10.0)

    def test_el_margen_pedido_gana_sobre_el_base(self) -> None:
        baseline = _baseline_fixture()
        projection = project_scenario(
            baseline, ScenarioVariables(ebitda_margin_pct=40.0)
        )

        assert projection.ebitda_margin_pct == pytest.approx(40.0)
        assert projection.ebitda == pytest.approx(40_000_000_000.0)

    def test_la_inflacion_comprime_el_margen_con_el_traspaso_declarado(self) -> None:
        """Con traspaso de 0,6, una inflación de 10% le resta 4 puntos al margen. Es un supuesto del
        modelo, declarado y configurable, no una medición.
        """

        baseline = _baseline_fixture()
        projection = project_scenario(baseline, ScenarioVariables(inflation_pct=10.0))

        assert projection.ebitda_margin_pct == pytest.approx(51.0)

    def test_un_margen_explicito_anula_el_efecto_de_la_inflacion(self) -> None:
        """Descontarle inflación a un margen que el usuario fijó sería contradecir lo que pidió."""

        baseline = _baseline_fixture()
        projection = project_scenario(
            baseline, ScenarioVariables(ebitda_margin_pct=45.0, inflation_pct=10.0)
        )

        assert projection.ebitda_margin_pct == pytest.approx(45.0)

    def test_la_tasa_de_interes_se_aplica_sobre_la_deuda_del_balance(self) -> None:
        baseline = _baseline_fixture()
        projection = project_scenario(
            baseline, ScenarioVariables(interest_rate_pct=15.0)
        )

        # 15% sobre 10.000 M de deuda = 1.500 M de intereses.
        assert projection.interest_expense == pytest.approx(1_500_000_000.0)
        # Y el resultado neto baja por los 500 M extra, netos de impuestos.
        assert projection.net_income is not None
        assert projection.net_income < (baseline.net_income or 0)

    def test_sin_deuda_la_tasa_no_mueve_nada(self) -> None:
        income = build_income_block(_income_row(interest=0.0))
        balance = build_balance_block(_balance_row(total_debt=0.0))
        baseline = build_baseline(
            income, balance, None, _metrics(), period=StatementPeriod.ANNUAL
        )

        projection = project_scenario(
            baseline, ScenarioVariables(interest_rate_pct=25.0)
        )
        assert projection.interest_expense == pytest.approx(0.0)

    def test_el_eps_sale_del_resultado_neto_sobre_las_acciones(self) -> None:
        baseline = _baseline_fixture()
        projection = project_scenario(
            baseline, ScenarioVariables(revenue_growth_pct=0.0)
        )

        assert projection.eps is not None
        assert projection.eps == pytest.approx(
            (projection.net_income or 0) / 24_500_000_000.0
        )

    def test_una_perdida_proyectada_no_se_grava(self) -> None:
        """Aplicarle la tasa a una pérdida la reduciría, mostrando un quebranto como si el fisco lo
        compensara en el mismo período.
        """

        baseline = _baseline_fixture()
        projection = project_scenario(
            baseline, ScenarioVariables(ebitda_margin_pct=1.0)
        )

        assert projection.net_income is not None
        assert projection.net_income < 0
        # Sin impuesto aplicado: el neto es exactamente operativo − intereses.
        assert projection.net_income == pytest.approx(
            (projection.operating_income or 0) - (projection.interest_expense or 0)
        )

    def test_el_precio_implicito_mantiene_el_multiplo(self) -> None:
        baseline = _baseline_fixture()
        projection = project_scenario(
            baseline, ScenarioVariables(revenue_growth_pct=20.0)
        )

        assert projection.implied_price is not None
        assert projection.implied_price == pytest.approx(62.5 * (projection.eps or 0))
        assert projection.implied_price_change_pct == pytest.approx(
            projection.eps_change_pct or 0, abs=0.01
        )

    def test_sin_multiplo_no_hay_precio_implicito_ni_cero(self) -> None:
        income = build_income_block(
            _income_row(operating_income=-8_000_000_000.0, ebitda=None)
        )
        balance = build_balance_block(_balance_row())
        baseline = build_baseline(
            income, balance, None, _metrics(), period=StatementPeriod.ANNUAL
        )

        projection = project_scenario(
            baseline, ScenarioVariables(revenue_growth_pct=10.0)
        )
        assert projection.implied_price is None
        assert projection.implied_price_change_pct is None

    def test_sin_ingresos_base_la_proyeccion_queda_vacia(self) -> None:
        income = build_income_block(_income_row(revenue=None))
        baseline = build_baseline(
            income, None, None, None, period=StatementPeriod.ANNUAL
        )

        projection = project_scenario(
            baseline, ScenarioVariables(revenue_growth_pct=10.0)
        )
        assert projection.revenue is None
        assert projection.eps is None

    def test_el_fcf_se_mueve_por_ebitda_intereses_e_impuestos(self) -> None:
        baseline = _baseline_fixture()
        projection = project_scenario(
            baseline, ScenarioVariables(revenue_growth_pct=10.0)
        )

        assert projection.free_cash_flow is not None
        # Sube, pero menos que el EBITDA: el impuesto sobre la ganancia extra se resta.
        assert projection.free_cash_flow > (baseline.free_cash_flow or 0)
        assert (
            projection.free_cash_flow < (baseline.free_cash_flow or 0) + 5_500_000_000.0
        )


class TestSensitivity:
    def test_la_matriz_tiene_los_tres_casos_ordenados(self) -> None:
        cases = build_sensitivity(_baseline_fixture(), ScenarioVariables())
        assert [case.case for case in cases] == [
            ScenarioCase.BEAR,
            ScenarioCase.BASE,
            ScenarioCase.BULL,
        ]

    def test_el_pesimista_da_menos_eps_que_el_optimista(self) -> None:
        cases = build_sensitivity(
            _baseline_fixture(), ScenarioVariables(revenue_growth_pct=10.0)
        )
        by_case = {case.case: case for case in cases}

        bear = by_case[ScenarioCase.BEAR].projection.eps
        base = by_case[ScenarioCase.BASE].projection.eps
        bull = by_case[ScenarioCase.BULL].projection.eps
        assert bear is not None and base is not None and bull is not None
        assert bear < base < bull

    def test_cada_caso_lleva_las_variables_que_lo_produjeron(self) -> None:
        """Un "bear" con un −18% de EPS no dice nada si no se puede ver que salió de crecer 5 puntos
        menos y perder 2 de margen.
        """

        cases = build_sensitivity(
            _baseline_fixture(),
            ScenarioVariables(revenue_growth_pct=10.0, ebitda_margin_pct=50.0),
        )
        bear = next(case for case in cases if case.case is ScenarioCase.BEAR)

        assert bear.variables.revenue_growth_pct == pytest.approx(5.0)
        assert bear.variables.ebitda_margin_pct == pytest.approx(48.0)

    def test_sin_margen_pedido_los_casos_no_inventan_uno(self) -> None:
        """Correr un margen que el usuario no fijó dejaría al caso pesimista con un margen explícito
        que él nunca eligió — y anularía el efecto de la inflación, que un margen explícito desactiva.
        """

        shifted = shift_variables(
            ScenarioVariables(revenue_growth_pct=10.0), growth_pp=-5.0, margin_pp=-2.0
        )
        assert shifted.ebitda_margin_pct is None
        assert shifted.revenue_growth_pct == pytest.approx(5.0)

    def test_el_corrimiento_respeta_los_limites_del_schema(self) -> None:
        # Sin el clamp, el corrimiento podría producir un valor que el propio schema rechaza.
        shifted = shift_variables(
            ScenarioVariables(revenue_growth_pct=-98.0, ebitda_margin_pct=-99.0),
            growth_pp=-5.0,
            margin_pp=-2.0,
        )
        assert shifted.revenue_growth_pct == pytest.approx(-100.0)
        assert shifted.ebitda_margin_pct == pytest.approx(-100.0)


class TestValuationBasis:
    def test_con_eps_positivo_la_base_es_el_multiplo_mantenido(self) -> None:
        basis, note = valuation_note(_baseline_fixture())
        assert basis is ValuationBasis.PE_MULTIPLE_HELD
        assert note is not None and "múltiplo" in note

    def test_sin_ganancia_en_el_punto_cero_se_declara_el_motivo(self) -> None:
        income = build_income_block(
            _income_row(operating_income=-8_000_000_000.0, ebitda=None)
        )
        baseline = build_baseline(
            income, None, None, _metrics(), period=StatementPeriod.ANNUAL
        )

        basis, note = valuation_note(baseline)
        assert basis is ValuationBasis.NOT_APPLICABLE
        assert note is not None and "no es positivo" in note

    def test_con_eps_infimo_se_declara_el_motivo_propio(self) -> None:
        """Los motivos se distinguen porque se arreglan distinto: sin precio falta el proveedor, sin
        ganancia no hay múltiplo, y con una ganancia ínfima el múltiplo amplifica hasta el absurdo.
        """

        # Operativo 1.200 M − intereses 1.000 M = 200 M de ganancia antes de impuestos: sobre 24.500
        # M de acciones, el EPS del modelo queda por debajo del piso de un centavo.
        income = build_income_block(
            _income_row(operating_income=1_200_000_000.0, ebitda=None, depreciation=0.0)
        )
        baseline = build_baseline(
            income, None, None, _metrics(), period=StatementPeriod.ANNUAL
        )

        basis, note = valuation_note(baseline)
        assert basis is ValuationBasis.NOT_APPLICABLE
        assert note is not None and "cercano a cero" in note


class TestModelAssumptions:
    def test_declara_siempre_lo_que_se_mantiene_constante(self) -> None:
        assumptions = build_model_assumptions(_baseline_fixture(), ScenarioVariables())
        joined = " ".join(assumptions)

        assert "NOMINAL" in joined
        assert "constantes" in joined

    def test_declara_el_traspaso_de_la_inflacion_como_supuesto(self) -> None:
        assumptions = build_model_assumptions(
            _baseline_fixture(), ScenarioVariables(inflation_pct=10.0)
        )
        joined = " ".join(assumptions)

        assert "4,00 puntos" in joined
        # El supuesto se declara COMO supuesto: sin eso, el coeficiente se lee como una medición.
        assert "no una medición" in joined

    def test_declara_que_el_evento_no_entra_en_ninguna_formula(self) -> None:
        assumptions = build_model_assumptions(
            _baseline_fixture(),
            ScenarioVariables(custom_event="Pierden el juicio antimonopolio."),
        )
        assert any("no entra en ninguna fórmula" in item for item in assumptions)

    def test_avisa_cuando_la_tasa_pedida_no_puede_hacer_nada(self) -> None:
        balance = build_balance_block(_balance_row(total_debt=0.0))
        baseline = build_baseline(
            build_income_block(_income_row()),
            balance,
            None,
            _metrics(),
            period=StatementPeriod.ANNUAL,
        )

        assumptions = build_model_assumptions(
            baseline, ScenarioVariables(interest_rate_pct=20.0)
        )
        assert any("no cambia nada" in item for item in assumptions)

    def test_declara_la_tasa_de_reserva_cuando_no_hay_efectiva(self) -> None:
        baseline = build_baseline(
            build_income_block(_income_row(pretax=None, tax=None)),
            build_balance_block(_balance_row()),
            None,
            _metrics(),
            period=StatementPeriod.ANNUAL,
        )

        assumptions = build_model_assumptions(baseline, ScenarioVariables())
        assert any("estatutaria" in item for item in assumptions)


# --- Prompts -----------------------------------------------------------------------------------


class TestPrompts:
    def test_el_prompt_del_analisis_lleva_los_numeros_ya_calculados(self) -> None:
        prompt = build_analysis_prompt(
            ticker="NVDA",
            period=StatementPeriod.ANNUAL,
            income=[build_income_block(_income_row())],
            balances=[build_balance_block(_balance_row())],
            cash_flows=[
                build_cash_flow_block(_cash_row(), net_income=39_200_000_000.0)
            ],
            dupont=build_dupont(
                build_income_block(_income_row()), build_balance_block(_balance_row())
            ),
            flags=evaluate_flags(
                [build_income_block(_income_row())],
                [build_balance_block(_balance_row())],
                [],
            ),
            question="¿Puede sostener la deuda?",
            history=[],
        )

        assert "<estado_de_resultados>" in prompt
        assert "<banderas_calculadas_en_codigo>" in prompt
        assert "¿Puede sostener la deuda?" in prompt
        # Los márgenes van resueltos: cada conversión que le dejemos al modelo es una oportunidad de
        # equivocarse en un número que después mostramos como propio.
        # El prompt es para el modelo, no para el usuario: ahí los números van en el formato que el
        # modelo lee sin ambigüedad (punto decimal), y la prosa que devuelve la escribe él.
        assert "margen neto 39.2%" in prompt

    def test_una_linea_ausente_se_declara_en_el_prompt(self) -> None:
        """El texto explícito y no un `null`: el modelo tiene que leer la ausencia como una
        instrucción de no hablar de ese dato.
        """

        prompt = build_analysis_prompt(
            ticker="NVDA",
            period=StatementPeriod.ANNUAL,
            income=[build_income_block(_income_row(revenue=None))],
            balances=[],
            cash_flows=[],
            dupont=build_dupont(None, None),
            flags=[],
            question=None,
            history=[],
        )

        assert "no disponible" in prompt
        assert "Sin balance general disponible." in prompt

    def test_el_prompt_del_escenario_prohibe_cuantificar_el_evento(self) -> None:
        baseline = _baseline_fixture()
        variables = ScenarioVariables(
            revenue_growth_pct=10.0, custom_event="Se cae la fusión."
        )
        prompt = build_scenario_prompt(
            ticker="NVDA",
            baseline=baseline,
            variables=variables,
            projection=project_scenario(baseline, variables),
            sensitivity=build_sensitivity(baseline, variables),
            basis=ValuationBasis.PE_MULTIPLE_HELD,
            assumptions=build_model_assumptions(baseline, variables),
        )

        assert "Se cae la fusión." in prompt
        assert "No inventes un porcentaje de impacto." in prompt

    def test_sin_precio_implicito_el_prompt_prohibe_hablar_de_precio(self) -> None:
        income = build_income_block(
            _income_row(operating_income=-8_000_000_000.0, ebitda=None)
        )
        baseline = build_baseline(
            income,
            build_balance_block(_balance_row()),
            None,
            _metrics(),
            period=StatementPeriod.ANNUAL,
        )
        variables = ScenarioVariables(revenue_growth_pct=5.0)

        prompt = build_scenario_prompt(
            ticker="NVDA",
            baseline=baseline,
            variables=variables,
            projection=project_scenario(baseline, variables),
            sensitivity=build_sensitivity(baseline, variables),
            basis=ValuationBasis.NOT_APPLICABLE,
            assumptions=[],
        )

        assert "no hables de precio objetivo" in prompt


# --- Servicio: análisis ------------------------------------------------------------------------


class TestAnalyzeService:
    async def test_sin_fmp_degrada_con_el_motivo(self) -> None:
        result = await _service().analyze(FinancialAnalysisRequest(ticker="nvda"))

        assert result.ticker == "NVDA"
        assert result.income_statements == []
        assert result.availability is DataAvailability.UNAVAILABLE
        assert result.degradation_reason == REASON_NO_FMP

    async def test_un_fallo_del_proveedor_se_distingue_de_no_tener_estados(
        self,
    ) -> None:
        failing = _service(fmp_client=_FakeFMP(status=DataStatus.ERROR_API))
        empty = _service(
            fmp_client=_FakeFMP(
                statements=_statements(income=[], balance=[], cash_flow=[])
            )
        )

        failed = await failing.analyze(FinancialAnalysisRequest(ticker="NVDA"))
        no_data = await empty.analyze(FinancialAnalysisRequest(ticker="NVDA"))

        assert failed.degradation_reason == REASON_FMP_FAILED
        # "Esta empresa no publica estados en el proveedor" es un dato, no una falla del sistema.
        assert no_data.degradation_reason == REASON_NO_STATEMENTS

    async def test_un_bug_del_cliente_no_tumba_la_vista(self) -> None:
        service = _service(fmp_client=_FakeFMP(raise_on_statements=True))
        result = await service.analyze(FinancialAnalysisRequest(ticker="NVDA"))

        assert result.availability is DataAvailability.UNAVAILABLE
        assert result.degradation_reason == REASON_FMP_FAILED

    async def test_devuelve_los_tres_estados_con_dupont_y_banderas(self) -> None:
        service = _service(fmp_client=_FakeFMP(statements=_statements()))
        result = await service.analyze(FinancialAnalysisRequest(ticker="NVDA"))

        assert result.availability is DataAvailability.AVAILABLE
        assert len(result.income_statements) == 1
        assert result.dupont.is_complete
        assert result.flags
        assert result.income_statements[0].net_margin_pct == pytest.approx(39.2)

    async def test_sin_gemini_los_numeros_quedan_y_solo_falta_la_prosa(self) -> None:
        service = _service(fmp_client=_FakeFMP(statements=_statements()))
        result = await service.analyze(FinancialAnalysisRequest(ticker="NVDA"))

        # El motivo va en el campo de la NARRATIVA, no en el general: la lista de estados llegó
        # perfecta y decir lo contrario haría creer que no hay análisis.
        assert result.degradation_reason is None
        assert result.narrative_degradation_reason == REASON_NO_GEMINI
        assert result.narrative is None
        assert result.narrative_source is NarrativeSource.NONE
        assert result.dupont.is_complete

    async def test_con_gemini_agrega_la_lectura_y_declara_su_origen(self) -> None:
        gemini = _FakeGemini()
        service = _service(
            fmp_client=_FakeFMP(statements=_statements()), gemini_client=gemini
        )

        result = await service.analyze(FinancialAnalysisRequest(ticker="NVDA"))

        assert result.narrative == "Lectura del analista."
        assert result.narrative_source is NarrativeSource.LLM
        assert result.narrative_degradation_reason is None

    async def test_un_fallo_del_modelo_no_borra_los_numeros(self) -> None:
        service = _service(
            fmp_client=_FakeFMP(statements=_statements()),
            gemini_client=_FakeGemini(status=DataStatus.ERROR_API),
        )
        result = await service.analyze(FinancialAnalysisRequest(ticker="NVDA"))

        assert result.narrative is None
        assert result.narrative_degradation_reason == REASON_GEMINI_FAILED
        assert result.income_statements
        assert result.availability is DataAvailability.AVAILABLE

    async def test_una_respuesta_ilegible_del_modelo_se_trata_como_fallo(self) -> None:
        service = _service(
            fmp_client=_FakeFMP(statements=_statements()),
            gemini_client=_FakeGemini(raw_json_text="no soy json"),
        )
        result = await service.analyze(FinancialAnalysisRequest(ticker="NVDA"))

        assert result.narrative is None
        assert result.narrative_degradation_reason == REASON_GEMINI_FAILED

    async def test_sin_estados_no_se_le_pide_nada_al_modelo(self) -> None:
        """Pedirle que escriba sobre un conjunto vacío devolvería exactamente la clase de texto
        plausible y sin respaldo que este módulo evita.
        """

        gemini = _FakeGemini()
        service = _service(
            fmp_client=_FakeFMP(
                statements=_statements(income=[], balance=[], cash_flow=[])
            ),
            gemini_client=gemini,
        )

        await service.analyze(FinancialAnalysisRequest(ticker="NVDA"))
        assert gemini.calls == 0

    async def test_el_historial_vuelve_con_el_turno_agregado(self) -> None:
        gemini = _FakeGemini()
        service = _service(
            fmp_client=_FakeFMP(statements=_statements()), gemini_client=gemini
        )

        result = await service.analyze(
            FinancialAnalysisRequest(
                ticker="NVDA",
                question="¿Cómo viene el margen?",
                history=[
                    ConversationTurn(role=ConversationRole.USER, content="Hola"),
                    ConversationTurn(role=ConversationRole.ASSISTANT, content="Hola."),
                ],
            )
        )

        assert [turn.content for turn in result.history[-2:]] == [
            "¿Cómo viene el margen?",
            "Lectura del analista.",
        ]
        # El historial previo se reinyecta en el prompt: es lo que mantiene el hilo.
        assert "<conversacion_previa>" in gemini.prompts[0]

    async def test_sin_pregunta_el_hilo_queda_vacio(self) -> None:
        """La lectura general se devuelve en `narrative`, no como un turno del hilo.

        Como turno se mostraba dos veces en la pantalla —informe y burbuja del analista— y volvía en
        el próximo request como una respuesta que nadie preguntó.
        """

        service = _service(
            fmp_client=_FakeFMP(statements=_statements()), gemini_client=_FakeGemini()
        )
        result = await service.analyze(FinancialAnalysisRequest(ticker="NVDA"))

        assert result.narrative == "Lectura del analista."
        assert result.history == []

    async def test_una_pregunta_no_borra_el_hilo_que_ya_venia(self) -> None:
        """El hilo previo sobrevive a un diagnóstico sin pregunta: recargar el activo no debería
        perder la conversación.
        """

        service = _service(
            fmp_client=_FakeFMP(statements=_statements()), gemini_client=_FakeGemini()
        )
        result = await service.analyze(
            FinancialAnalysisRequest(
                ticker="NVDA",
                history=[
                    ConversationTurn(role=ConversationRole.USER, content="¿Y la caja?"),
                    ConversationTurn(
                        role=ConversationRole.ASSISTANT, content="Convierte casi todo."
                    ),
                ],
            )
        )

        assert [turn.content for turn in result.history] == [
            "¿Y la caja?",
            "Convierte casi todo.",
        ]

    async def test_los_estados_se_cachean_por_ticker_y_periodicidad(self) -> None:
        fmp = _FakeFMP(statements=_statements())
        service = _service(fmp_client=fmp)

        await service.analyze(FinancialAnalysisRequest(ticker="NVDA"))
        await service.analyze(FinancialAnalysisRequest(ticker="NVDA"))
        assert len(fmp.statement_calls) == 1

        # Anual y trimestral son dos preguntas distintas: un margen trimestral y uno anual no se
        # comparan entre sí.
        await service.analyze(
            FinancialAnalysisRequest(ticker="NVDA", period=StatementPeriod.QUARTER)
        )
        assert len(fmp.statement_calls) == 2
        assert fmp.statement_calls[-1]["period"] == "quarter"

    async def test_la_segunda_lectura_se_marca_como_cacheada(self) -> None:
        service = _service(fmp_client=_FakeFMP(statements=_statements()))

        first = await service.analyze(FinancialAnalysisRequest(ticker="NVDA"))
        second = await service.analyze(FinancialAnalysisRequest(ticker="NVDA"))

        assert first.served_from_cache is False
        assert second.served_from_cache is True

    async def test_un_fallo_del_proveedor_no_se_cachea(self) -> None:
        """El proveedor se recupera en segundos; cachear el fallo lo convierte en seis horas de
        "esta empresa no publica estados".
        """

        fmp = _FakeFMP(status=DataStatus.ERROR_API)
        service = _service(fmp_client=fmp)

        await service.analyze(FinancialAnalysisRequest(ticker="NVDA"))
        await service.analyze(FinancialAnalysisRequest(ticker="NVDA"))
        assert len(fmp.statement_calls) == 2

    async def test_el_flujo_de_caja_se_aparea_por_fecha_y_no_por_posicion(self) -> None:
        """Los tres endpoints pueden traer distinta cantidad de filas: aparearlos por índice mezclaría
        el FCF de un año con la ganancia de otro.
        """

        service = _service(
            fmp_client=_FakeFMP(
                statements=_statements(
                    income=[
                        _income_row(date="2026-01-31", net_income=39_200_000_000.0),
                        _income_row(date="2025-01-31", net_income=10_000_000_000.0),
                    ],
                    # Solo el año viejo tiene flujo de caja.
                    cash_flow=[_cash_row(date="2025-01-31", fcf=5_000_000_000.0)],
                )
            )
        )

        result = await service.analyze(FinancialAnalysisRequest(ticker="NVDA"))
        # 5.000 sobre los 10.000 del MISMO año = 50%, no sobre los 39.200 del año nuevo.
        assert result.cash_flows[0].fcf_conversion_pct == pytest.approx(50.0)


# --- Servicio: simulador -----------------------------------------------------------------------


class TestSimulateService:
    async def test_sin_fmp_degrada_con_el_motivo(self) -> None:
        result = await _service().simulate(ScenarioSimulationRequest(ticker="NVDA"))

        assert result.availability is DataAvailability.UNAVAILABLE
        assert result.degradation_reason == REASON_NO_FMP
        assert result.projection.eps is None

    async def test_sin_lineas_minimas_lo_declara_en_vez_de_proyectar_ceros(
        self,
    ) -> None:
        """Una proyección de ceros se leería como "esta empresa no va a facturar nada"."""

        service = _service(
            fmp_client=_FakeFMP(
                statements=_statements(
                    income=[_income_row(revenue=None, net_income=None)]
                )
            )
        )
        result = await service.simulate(ScenarioSimulationRequest(ticker="NVDA"))

        assert result.availability is DataAvailability.UNAVAILABLE
        assert result.degradation_reason == REASON_NO_BASELINE

    async def test_devuelve_base_proyeccion_matriz_y_supuestos(self) -> None:
        service = _service(fmp_client=_FakeFMP(statements=_statements()))
        result = await service.simulate(
            ScenarioSimulationRequest(
                ticker="NVDA", variables=ScenarioVariables(revenue_growth_pct=15.0)
            )
        )

        assert result.availability is DataAvailability.AVAILABLE
        assert result.baseline.revenue == pytest.approx(100_000_000_000.0)
        assert result.projection.revenue == pytest.approx(115_000_000_000.0)
        assert len(result.sensitivity) == 3
        assert result.model_assumptions
        assert result.valuation_basis is ValuationBasis.PE_MULTIPLE_HELD

    async def test_un_escenario_solo_con_rumor_lo_declara_cualitativo(self) -> None:
        service = _service(fmp_client=_FakeFMP(statements=_statements()))
        result = await service.simulate(
            ScenarioSimulationRequest(
                ticker="NVDA",
                variables=ScenarioVariables(custom_event="Se rumorea una adquisición."),
            )
        )

        assert result.custom_event == "Se rumorea una adquisición."
        assert result.custom_event_is_qualitative is True
        # El rumor no movió NADA: la proyección es igual a la base.
        assert result.projection.revenue == pytest.approx(result.baseline.revenue or 0)
        assert result.projection.eps_change_pct == pytest.approx(0.0, abs=0.01)

    async def test_sin_gemini_la_simulacion_conserva_todos_sus_numeros(self) -> None:
        service = _service(fmp_client=_FakeFMP(statements=_statements()))
        result = await service.simulate(
            ScenarioSimulationRequest(
                ticker="NVDA", variables=ScenarioVariables(revenue_growth_pct=10.0)
            )
        )

        assert result.projection.eps is not None
        assert result.narrative is None
        assert result.narrative_degradation_reason == REASON_NO_GEMINI
        assert result.degradation_reason is None

    async def test_con_gemini_agrega_la_explicacion(self) -> None:
        gemini = _FakeGemini()
        service = _service(
            fmp_client=_FakeFMP(statements=_statements()), gemini_client=gemini
        )
        result = await service.simulate(
            ScenarioSimulationRequest(
                ticker="NVDA", variables=ScenarioVariables(revenue_growth_pct=10.0)
            )
        )

        assert result.narrative == "Lectura del analista."
        assert result.narrative_source is NarrativeSource.LLM
        # El prompt recibió la proyección YA calculada, con la matriz.
        assert "<proyeccion_calculada_en_codigo>" in gemini.prompts[0]
        assert "<matriz_de_sensibilidad>" in gemini.prompts[0]

    async def test_el_precio_de_referencia_usa_la_capitalizacion(self) -> None:
        fmp = _FakeFMP(statements=_statements())
        service = _service(fmp_client=fmp)

        result = await service.simulate(ScenarioSimulationRequest(ticker="NVDA"))

        assert fmp.metrics_calls == 1
        assert result.baseline.reference_price == pytest.approx(100.0)

    async def test_la_capitalizacion_se_cachea_aparte_de_los_estados(self) -> None:
        """Dos TTL distintos porque los datos envejecen distinto: un balance publicado no cambia
        hasta el próximo reporte y la capitalización se mueve con el precio durante la rueda.
        """

        fmp = _FakeFMP(statements=_statements())
        service = _service(fmp_client=fmp)

        await service.simulate(ScenarioSimulationRequest(ticker="NVDA"))
        await service.simulate(ScenarioSimulationRequest(ticker="NVDA"))

        assert fmp.metrics_calls == 1
        assert len(fmp.statement_calls) == 1


# --- Endpoints ---------------------------------------------------------------------------------


class TestEndpoints:
    async def test_los_dos_exigen_autenticacion(
        self, client: httpx.AsyncClient
    ) -> None:
        analysis = await client.post(
            "/api/v1/ai-lab/financial-analysis", json={"ticker": "NVDA"}
        )
        simulate = await client.post("/api/v1/ai-lab/simulate", json={"ticker": "NVDA"})

        assert analysis.status_code == 401
        assert simulate.status_code == 401

    async def test_sin_credenciales_responden_200_degradado(
        self, client: httpx.AsyncClient
    ) -> None:
        """Un 503 obligaría al cliente a traducir "no configurado" a un aviso, que es exactamente lo
        que la respuesta ya trae.
        """

        headers = await _auth(client, "ailab-degraded@example.com")

        analysis = await client.post(
            "/api/v1/ai-lab/financial-analysis",
            json={"ticker": "NVDA"},
            headers=headers,
        )
        simulate = await client.post(
            "/api/v1/ai-lab/simulate", json={"ticker": "NVDA"}, headers=headers
        )

        assert analysis.status_code == 200
        assert analysis.json()["availability"] == "UNAVAILABLE"
        assert analysis.json()["degradation_reason"] == REASON_NO_FMP
        assert simulate.status_code == 200
        assert simulate.json()["availability"] == "UNAVAILABLE"

    async def test_el_analisis_devuelve_los_bloques_calculados(
        self, client: httpx.AsyncClient
    ) -> None:
        app.state.ai_lab_service = _service(
            fmp_client=_FakeFMP(statements=_statements()), gemini_client=_FakeGemini()
        )
        headers = await _auth(client, "ailab-analysis@example.com")

        response = await client.post(
            "/api/v1/ai-lab/financial-analysis",
            json={"ticker": "nvda", "question": "¿Cómo está el balance?"},
            headers=headers,
        )

        body = response.json()
        assert response.status_code == 200
        assert body["ticker"] == "NVDA"
        assert body["dupont"]["roe_pct"] is not None
        assert body["flags"]
        assert body["narrative_source"] == "LLM"
        assert [turn["role"] for turn in body["history"]] == ["USER", "ASSISTANT"]

    async def test_el_simulador_devuelve_la_matriz_y_los_supuestos(
        self, client: httpx.AsyncClient
    ) -> None:
        app.state.ai_lab_service = _service(
            fmp_client=_FakeFMP(statements=_statements())
        )
        headers = await _auth(client, "ailab-sim@example.com")

        response = await client.post(
            "/api/v1/ai-lab/simulate",
            json={
                "ticker": "NVDA",
                "variables": {
                    "revenue_growth_pct": 12.0,
                    "ebitda_margin_pct": 52.0,
                    "interest_rate_pct": 8.0,
                    "inflation_pct": 4.0,
                    "custom_event": "Un competidor lanza un producto más barato.",
                },
            },
            headers=headers,
        )

        body = response.json()
        assert response.status_code == 200
        assert len(body["sensitivity"]) == 3
        assert body["valuation_basis"] == "PE_MULTIPLE_HELD"
        assert body["custom_event_is_qualitative"] is True
        assert body["model_assumptions"]

    async def test_el_periodo_viaja_como_string_igual_que_desde_el_cliente(
        self, client: httpx.AsyncClient
    ) -> None:
        """JSON no tiene tipo nativo para Enum: el período llega como `"QUARTER"`, no como
        `StatementPeriod`.

        Es el cuerpo exacto que manda la app, y con los schemas de request en modo estricto los dos
        endpoints lo rechazaban con 422 — la pantalla mostraba "error de red" sin haber pedido nada
        raro.
        """

        app.state.ai_lab_service = _service(
            fmp_client=_FakeFMP(statements=_statements())
        )
        headers = await _auth(client, "ailab-period@example.com")

        analysis = await client.post(
            "/api/v1/ai-lab/financial-analysis",
            json={"ticker": "NVDA", "period": "QUARTER"},
            headers=headers,
        )
        simulate = await client.post(
            "/api/v1/ai-lab/simulate",
            json={"ticker": "NVDA", "period": "QUARTER", "variables": {}},
            headers=headers,
        )

        assert analysis.status_code == 200
        assert analysis.json()["period"] == "QUARTER"
        assert simulate.status_code == 200
        assert simulate.json()["baseline"] is not None

    async def test_un_rol_del_historial_viaja_como_string(
        self, client: httpx.AsyncClient
    ) -> None:
        """Mismo caso que el período, con el hilo que el cliente devuelve turno a turno."""

        app.state.ai_lab_service = _service(
            fmp_client=_FakeFMP(statements=_statements()), gemini_client=_FakeGemini()
        )
        headers = await _auth(client, "ailab-role@example.com")

        response = await client.post(
            "/api/v1/ai-lab/financial-analysis",
            json={
                "ticker": "NVDA",
                "question": "¿Y la caja?",
                "history": [
                    {"role": "USER", "content": "¿De dónde viene el ROE?"},
                    {"role": "ASSISTANT", "content": "Del margen."},
                ],
            },
            headers=headers,
        )

        body = response.json()
        assert response.status_code == 200
        assert [turn["role"] for turn in body["history"]] == [
            "USER",
            "ASSISTANT",
            "USER",
            "ASSISTANT",
        ]

    async def test_una_palanca_redonda_viaja_como_entero(
        self, client: httpx.AsyncClient
    ) -> None:
        """Un slider en 25% serializa `25`, no `25.0`: JSON no distingue, y en modo estricto un
        entero no es un float.
        """

        app.state.ai_lab_service = _service(
            fmp_client=_FakeFMP(statements=_statements())
        )
        headers = await _auth(client, "ailab-int@example.com")

        response = await client.post(
            "/api/v1/ai-lab/simulate",
            json={"ticker": "NVDA", "variables": {"revenue_growth_pct": 25}},
            headers=headers,
        )

        body = response.json()
        assert response.status_code == 200
        assert body["applied_variables"]["revenue_growth_pct"] == 25.0

    async def test_una_variable_fuera_de_rango_es_422(
        self, client: httpx.AsyncClient
    ) -> None:
        """Un crecimiento de +10.000% no es un escenario, es un error de tipeo — y proyectarlo daría
        un precio implícito que el cliente mostraría en serio.
        """

        headers = await _auth(client, "ailab-range@example.com")

        response = await client.post(
            "/api/v1/ai-lab/simulate",
            json={"ticker": "NVDA", "variables": {"revenue_growth_pct": 10000.0}},
            headers=headers,
        )
        assert response.status_code == 422

    async def test_un_nan_en_una_variable_es_422(
        self, client: httpx.AsyncClient
    ) -> None:
        headers = await _auth(client, "ailab-nan@example.com")

        response = await client.post(
            "/api/v1/ai-lab/simulate",
            content='{"ticker": "NVDA", "variables": {"revenue_growth_pct": NaN}}',
            headers={**headers, "content-type": "application/json"},
        )
        assert response.status_code == 422

    async def test_un_historial_demasiado_largo_es_422(
        self, client: httpx.AsyncClient
    ) -> None:
        """Sin tope, un cliente podría empujar un prompt de megabytes."""

        headers = await _auth(client, "ailab-history@example.com")

        response = await client.post(
            "/api/v1/ai-lab/financial-analysis",
            json={
                "ticker": "NVDA",
                "history": [
                    {"role": "USER", "content": f"turno {index}"} for index in range(25)
                ],
            },
            headers=headers,
        )
        assert response.status_code == 422

    async def test_un_campo_desconocido_es_422(self, client: httpx.AsyncClient) -> None:
        headers = await _auth(client, "ailab-extra@example.com")

        response = await client.post(
            "/api/v1/ai-lab/simulate",
            json={"ticker": "NVDA", "variables": {"tasa_magica": 5}},
            headers=headers,
        )
        assert response.status_code == 422
