"""Servicio del Laboratorio Financiero: diagnóstico contable y simulador de escenarios.

**La regla que organiza todo el archivo: los números se calculan acá, la prosa la escribe el modelo.**

Ninguna cifra de la respuesta pasa por Gemini. Los márgenes, la descomposición DuPont, las banderas,
la proyección del escenario y el precio implícito salen de funciones puras con umbrales explícitos,
testeables y reproducibles. Al modelo se le manda el resultado YA CALCULADO y se le pide una sola
cosa: explicarlo en castellano. El prompt se lo dice y la respuesta lo declara en `narrative_source`.

Eso incluye el "rumor hecho realidad": `custom_event` es texto libre y su efecto es **cualitativo**.
Dejar que un rumor moviera las cuentas significaría que el modelo elige un coeficiente —"un juicio
perdido baja las ventas un 12%"— y ese 12% no lo midió nadie. La respuesta trae
`custom_event_is_qualitative=True` para que el cliente pueda decirlo.

El modelo de proyección es simple a propósito y se publica entero en `model_assumptions`:

  - Ingresos: se aplica el crecimiento pedido. **La inflación no se suma acá**: el crecimiento que
    entra ya es nominal, y sumarlos contaría dos veces lo mismo.
  - Margen EBITDA: el que se pida. Si no se pide ninguno, se parte del margen base y la inflación le
    resta puntos según un traspaso a precios declarado (ver `_COST_PASS_THROUGH`).
  - Intereses: la deuda se mantiene constante y se le aplica la tasa pedida. La tasa base se deduce
    del gasto de intereses sobre la deuda, no se supone.
  - Impuestos: la tasa efectiva del período base; si no se puede calcular, la estatutaria declarada.
  - D&A, capex y capital de trabajo: constantes.
  - Precio: se mantiene el múltiplo precio/ganancias y se mueve el EPS. Es una convención declarada
    (`valuation_basis`), no una valuación.

Degradaciones, todas con la misma forma (respuesta válida + `availability` + motivo):

  - **Sin FMP** → sin estados contables, sin análisis y sin simulación, con el motivo.
  - **El proveedor no tiene los estados** → listas vacías con `AVAILABLE`: "esta empresa no publica
    estados en el proveedor" no es una falla del sistema.
  - **Sin Gemini** → el análisis conserva TODOS sus números y sus banderas; lo único que falta es la
    prosa, y su motivo va en un campo aparte del general.
"""

from __future__ import annotations

import asyncio
import json
import logging
import math
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any, NamedTuple

from pydantic import BaseModel, ConfigDict, ValidationError

from app.core.ttl_cache import TtlCache
from app.schemas.ai_lab import (
    MAX_HISTORY_TURNS,
    MAX_STATEMENT_PERIODS,
    MAX_TURN_CHARS,
    MIN_ABS_DENOMINATOR,
    MIN_ABS_EPS_FOR_MULTIPLE,
    AnalysisFlag,
    BalanceSheetBlock,
    CashFlowBlock,
    ConversationRole,
    ConversationTurn,
    CriteriaSource,
    DupontBlock,
    FinancialAnalysisRequest,
    FinancialAnalysisResponse,
    FlagKind,
    FlagSeverity,
    IncomeStatementBlock,
    NarrativeSource,
    ScenarioBaseline,
    ScenarioCase,
    ScenarioProjection,
    ScenarioSimulationRequest,
    ScenarioSimulationResult,
    ScenarioVariables,
    SensitivityCase,
    StatementPeriod,
    ValuationBasis,
)
from app.schemas.intelligence import DataAvailability
from src.ingestion.fmp_client import FMPClient
from src.ingestion.gemini_client import GeminiClient
from src.ingestion.schemas_raw import FinancialStatements
from src.validation.domain_models import DataStatus, FinancialMetrics

logger = logging.getLogger(__name__)

_PROMPTS_DIR = Path(__file__).resolve().parent.parent.parent / "prompts"
_ANALYSIS_PROMPT_PATH = _PROMPTS_DIR / "ai_lab_analysis_system_prompt.md"
_SCENARIO_PROMPT_PATH = _PROMPTS_DIR / "ai_lab_scenario_system_prompt.md"

# --- Motivos de degradación ----------------------------------------------------------------------

REASON_NO_FMP = (
    "El proveedor de estados contables no está configurado en este entorno, así que no hay "
    "balance ni estado de resultados para analizar."
)
REASON_FMP_FAILED = "El proveedor de estados contables no respondió en este momento. Probá de nuevo en un rato."
REASON_NO_STATEMENTS = (
    "El proveedor no publica estados contables de este símbolo. Puede ser un ETF, un ADR o una "
    "empresa que no reporta ante la SEC."
)
REASON_NO_GEMINI = (
    "La lectura escrita por IA no está disponible en este entorno; los números y las banderas de "
    "arriba se calcularon igual."
)
REASON_GEMINI_FAILED = (
    "No se pudo generar la lectura escrita en este momento; los números y las banderas de arriba "
    "se calcularon igual."
)
REASON_NO_BASELINE = (
    "Faltan las líneas contables mínimas (ingresos y resultado neto) para armar un punto de "
    "partida, así que no se puede proyectar un escenario."
)

# --- Supuestos del modelo de proyección ----------------------------------------------------------

# Cuánto de la inflación de costos se traspasa a precios. Es un SUPUESTO del modelo, declarado y
# configurable, no una medición: con 0,6 se asume que una empresa recupera en precios seis de cada
# diez puntos de inflación y los cuatro restantes le comen margen.
#
# Existe porque la alternativa era peor: dejar que la inflación no hiciera nada (y entonces la
# variable sería decorativa) o pedirle al modelo que estime el impacto (y entonces el número lo
# inventa un LLM). Acá está a la vista y se puede discutir.
_COST_PASS_THROUGH = 0.6

# Tasa impositiva de reserva cuando la efectiva del período base no se puede calcular. Es la
# estatutaria federal de EE.UU., que es de donde son las empresas del catálogo.
_FALLBACK_TAX_RATE_PCT = 21.0

# Rango en el que se considera creíble una tasa efectiva calculada. Un período con quebrantos puede
# dar una tasa negativa o del 300%: proyectar con eso multiplica el error.
_MIN_CREDIBLE_TAX_RATE_PCT = 0.0
_MAX_CREDIBLE_TAX_RATE_PCT = 60.0

# Cuánto se corre cada palanca para armar los casos pesimista y optimista de la matriz. Son puntos
# porcentuales y están acá para que la matriz sea reproducible: sin constantes explícitas, "bear" no
# significa nada comparable entre dos corridas.
_CASE_GROWTH_SHIFT_PP = 5.0
_CASE_MARGIN_SHIFT_PP = 2.0

# --- Alias de líneas contables --------------------------------------------------------------------
# Los nombres varían entre la API legacy de FMP y la `stable`. Se prueban en orden y el primero que
# traiga un número gana; si ninguno matchea, la línea queda en `None` y se declara ausente — nunca en
# 0, que se leería como "la empresa no tiene deuda".

_REVENUE_KEYS = ("revenue", "totalRevenue")
_COST_OF_REVENUE_KEYS = ("costOfRevenue", "costOfGoodsSold")
_GROSS_PROFIT_KEYS = ("grossProfit",)
_OPERATING_EXPENSES_KEYS = ("operatingExpenses", "totalOperatingExpenses")
_OPERATING_INCOME_KEYS = ("operatingIncome", "operatingIncomeLoss")
_EBITDA_KEYS = ("ebitda", "EBITDA")
_DA_KEYS = (
    "depreciationAndAmortization",
    "depreciationAmortization",
    "depreciationAndAmortisation",
)
_INTEREST_EXPENSE_KEYS = ("interestExpense", "interestExpenseNet")
_PRETAX_INCOME_KEYS = ("incomeBeforeTax", "pretaxIncome", "incomeBeforeIncomeTaxes")
_TAX_EXPENSE_KEYS = ("incomeTaxExpense", "provisionForIncomeTaxes")
_NET_INCOME_KEYS = ("netIncome", "netIncomeLoss")
_EPS_DILUTED_KEYS = ("epsDiluted", "epsdiluted", "eps")
_SHARES_DILUTED_KEYS = (
    "weightedAverageShsOutDil",
    "weightedAverageShsOut",
    "dilutedSharesOutstanding",
)

_TOTAL_ASSETS_KEYS = ("totalAssets",)
_CURRENT_ASSETS_KEYS = ("totalCurrentAssets",)
_CASH_KEYS = ("cashAndCashEquivalents", "cashAndShortTermInvestments")
_INVENTORY_KEYS = ("inventory", "inventories")
_TOTAL_LIABILITIES_KEYS = ("totalLiabilities",)
_CURRENT_LIABILITIES_KEYS = ("totalCurrentLiabilities",)
_TOTAL_DEBT_KEYS = ("totalDebt",)
_LONG_TERM_DEBT_KEYS = ("longTermDebt",)
_SHORT_TERM_DEBT_KEYS = ("shortTermDebt",)
_EQUITY_KEYS = (
    "totalStockholdersEquity",
    "totalEquity",
    "totalShareholdersEquity",
)

_OCF_KEYS = ("operatingCashFlow", "netCashProvidedByOperatingActivities")
_CAPEX_KEYS = ("capitalExpenditure", "investmentsInPropertyPlantAndEquipment")
_FCF_KEYS = ("freeCashFlow",)
_DIVIDENDS_KEYS = ("netDividendsPaid", "dividendsPaid", "commonDividendsPaid")
_BUYBACK_KEYS = ("commonStockRepurchased", "netStockRepurchase")
_NET_CASH_CHANGE_KEYS = ("netChangeInCash", "cashAtEndOfPeriod")

_PERIOD_END_KEYS = ("date", "fiscalDateEnding", "periodEnding")
_PERIOD_LABEL_KEYS = ("period", "calendarYear", "fiscalYear")


# --- Utilidades numéricas ------------------------------------------------------------------------


def _number(row: dict[str, Any], keys: tuple[str, ...]) -> float | None:
    """El primer alias con un número real. Los booleanos se descartan explícitamente: en Python
    `isinstance(True, int)` es verdadero, y un `True` colado desde el proveedor entraría como 1.
    """

    for key in keys:
        if key not in row:
            continue
        raw = row[key]
        if isinstance(raw, bool):
            continue
        if isinstance(raw, (int, float)):
            value = float(raw)
            # NaN/inf entran por JSON como floats válidos y contaminan cualquier cálculo que los
            # toque. Se descartan como si la línea no viniera.
            if math.isfinite(value):
                return value
        elif isinstance(raw, str):
            try:
                return float(raw)
            except ValueError:
                continue
    return None


def _text(row: dict[str, Any], keys: tuple[str, ...]) -> str | None:
    for key in keys:
        raw = row.get(key)
        if isinstance(raw, str) and raw.strip():
            return raw.strip()
        if isinstance(raw, int) and not isinstance(raw, bool):
            return str(raw)
    return None


def _parse_date(raw: Any) -> date | None:
    if not isinstance(raw, str) or not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).date()
    except ValueError:
        return None


def safe_ratio(
    numerator: float | None,
    denominator: float | None,
    *,
    min_abs_denominator: float = MIN_ABS_DENOMINATOR,
) -> float | None:
    """Cociente, o `None` si la base es demasiado chica para que signifique algo.

    El piso es la única defensa contra el modo de falla más común de un análisis contable
    automático: un margen de 4.000% calculado sobre ingresos de cien mil dólares en un trimestre de
    transición. El número existiría y sería basura.
    """

    if numerator is None or denominator is None:
        return None
    if abs(denominator) < min_abs_denominator:
        return None
    return numerator / denominator


def safe_pct(
    numerator: float | None,
    denominator: float | None,
    *,
    min_abs_denominator: float = MIN_ABS_DENOMINATOR,
) -> float | None:
    ratio = safe_ratio(numerator, denominator, min_abs_denominator=min_abs_denominator)
    return None if ratio is None else ratio * 100.0


def change_pct(new: float | None, old: float | None) -> float | None:
    """Variación porcentual contra una base.

    Requiere una base POSITIVA: la variación porcentual sobre una base negativa cambia de signo sin
    que el negocio haya mejorado ni empeorado (pasar de −100 a −50 no es "+50%"), y mostrarla sería
    peor que no mostrar nada.
    """

    if new is None or old is None or old <= 0:
        return None
    return (new - old) / old * 100.0


# --- Bloques contables ---------------------------------------------------------------------------


def build_income_block(row: dict[str, Any]) -> IncomeStatementBlock:
    """Un período del estado de resultados, con sus márgenes.

    El EBITDA se reconstruye como resultado operativo + D&A cuando el proveedor no lo publica, y eso
    queda marcado en `ebitda_is_derived`: un EBITDA reconstruido puede no coincidir con el que la
    empresa informa en su presentación (que suele excluir cargos no recurrentes), y presentarlos como
    la misma cosa sería atribuirle a la empresa un número que no dijo.
    """

    revenue = _number(row, _REVENUE_KEYS)
    operating_income = _number(row, _OPERATING_INCOME_KEYS)
    depreciation = _number(row, _DA_KEYS)

    ebitda = _number(row, _EBITDA_KEYS)
    ebitda_is_derived = False
    if ebitda is None and operating_income is not None and depreciation is not None:
        ebitda = operating_income + depreciation
        ebitda_is_derived = True

    net_income = _number(row, _NET_INCOME_KEYS)
    pretax = _number(row, _PRETAX_INCOME_KEYS)
    tax = _number(row, _TAX_EXPENSE_KEYS)

    return IncomeStatementBlock(
        period_end=_parse_date(_text(row, _PERIOD_END_KEYS)),
        period_label=_text(row, _PERIOD_LABEL_KEYS),
        revenue=revenue,
        cost_of_revenue=_number(row, _COST_OF_REVENUE_KEYS),
        gross_profit=_number(row, _GROSS_PROFIT_KEYS),
        operating_expenses=_number(row, _OPERATING_EXPENSES_KEYS),
        operating_income=operating_income,
        ebitda=ebitda,
        ebitda_is_derived=ebitda_is_derived,
        depreciation_amortization=depreciation,
        # El gasto de intereses se normaliza a POSITIVO: algunos endpoints lo mandan como negativo
        # (es un egreso) y otros como positivo. Sin normalizar, la cobertura de intereses saldría con
        # el signo dado vuelta y una empresa sólida aparecería en rojo.
        interest_expense=(
            None
            if (raw_interest := _number(row, _INTEREST_EXPENSE_KEYS)) is None
            else abs(raw_interest)
        ),
        income_before_tax=pretax,
        income_tax_expense=tax,
        net_income=net_income,
        eps_diluted=_number(row, _EPS_DILUTED_KEYS),
        weighted_shares_diluted=_number(row, _SHARES_DILUTED_KEYS),
        gross_margin_pct=safe_pct(_number(row, _GROSS_PROFIT_KEYS), revenue),
        operating_margin_pct=safe_pct(operating_income, revenue),
        ebitda_margin_pct=safe_pct(ebitda, revenue),
        net_margin_pct=safe_pct(net_income, revenue),
        # La tasa efectiva se calcula sobre el resultado antes de impuestos y solo si es POSITIVO: en
        # un período con pérdidas el cociente da un número sin interpretación contable.
        effective_tax_rate_pct=(safe_pct(tax, pretax) if (pretax or 0) > 0 else None),
    )


def build_balance_block(row: dict[str, Any]) -> BalanceSheetBlock:
    """Un período del balance general, con los ratios de estructura.

    La deuda total se reconstruye sumando corto y largo plazo cuando el proveedor no publica el
    agregado: es una suma de líneas del mismo balance, no una estimación.
    """

    total_debt = _number(row, _TOTAL_DEBT_KEYS)
    if total_debt is None:
        short_term = _number(row, _SHORT_TERM_DEBT_KEYS)
        long_term = _number(row, _LONG_TERM_DEBT_KEYS)
        if short_term is not None or long_term is not None:
            total_debt = (short_term or 0.0) + (long_term or 0.0)

    cash = _number(row, _CASH_KEYS)
    equity = _number(row, _EQUITY_KEYS)
    total_assets = _number(row, _TOTAL_ASSETS_KEYS)
    current_assets = _number(row, _CURRENT_ASSETS_KEYS)
    current_liabilities = _number(row, _CURRENT_LIABILITIES_KEYS)

    return BalanceSheetBlock(
        period_end=_parse_date(_text(row, _PERIOD_END_KEYS)),
        period_label=_text(row, _PERIOD_LABEL_KEYS),
        total_assets=total_assets,
        current_assets=current_assets,
        cash_and_equivalents=cash,
        inventory=_number(row, _INVENTORY_KEYS),
        total_liabilities=_number(row, _TOTAL_LIABILITIES_KEYS),
        current_liabilities=current_liabilities,
        total_debt=total_debt,
        total_equity=equity,
        current_ratio=safe_ratio(current_assets, current_liabilities),
        # El apalancamiento requiere patrimonio POSITIVO: con patrimonio negativo el ratio da un
        # número negativo que se leería como "poca deuda", que es lo contrario de lo que pasa.
        debt_to_equity=(safe_ratio(total_debt, equity) if (equity or 0) > 0 else None),
        net_debt=(None if total_debt is None or cash is None else total_debt - cash),
        equity_ratio_pct=safe_pct(equity, total_assets),
    )


def build_cash_flow_block(
    row: dict[str, Any],
    *,
    revenue: float | None = None,
    net_income: float | None = None,
) -> CashFlowBlock:
    """Un período del flujo de caja.

    `revenue` y `net_income` vienen del estado de resultados del MISMO período: la conversión de
    resultado a caja cruza los dos estados, y calcularla acá evita que el cliente tenga que
    apareárselos (y equivocarse de período al hacerlo).
    """

    operating = _number(row, _OCF_KEYS)
    capex = _number(row, _CAPEX_KEYS)

    free_cash_flow = _number(row, _FCF_KEYS)
    fcf_is_derived = False
    if free_cash_flow is None and operating is not None and capex is not None:
        # El capex viene como negativo en la mayoría de los endpoints (es una salida de caja), así
        # que se suma en valor absoluto restándolo: FCF = OCF − |capex|.
        free_cash_flow = operating - abs(capex)
        fcf_is_derived = True

    return CashFlowBlock(
        period_end=_parse_date(_text(row, _PERIOD_END_KEYS)),
        period_label=_text(row, _PERIOD_LABEL_KEYS),
        operating_cash_flow=operating,
        capital_expenditure=capex,
        free_cash_flow=free_cash_flow,
        free_cash_flow_is_derived=fcf_is_derived,
        dividends_paid=_number(row, _DIVIDENDS_KEYS),
        share_repurchases=_number(row, _BUYBACK_KEYS),
        net_change_in_cash=_number(row, _NET_CASH_CHANGE_KEYS),
        # La conversión se mide solo contra un resultado neto POSITIVO: con pérdidas, el cociente
        # invierte el signo y una empresa que quema caja aparecería con "conversión positiva".
        fcf_conversion_pct=(
            safe_pct(free_cash_flow, net_income) if (net_income or 0) > 0 else None
        ),
        capex_to_revenue_pct=(None if capex is None else safe_pct(abs(capex), revenue)),
    )


def build_dupont(
    income: IncomeStatementBlock | None, balance: BalanceSheetBlock | None
) -> DupontBlock:
    """Descomposición DuPont: ROE = margen neto × rotación de activos × apalancamiento.

    Los tres factores se calculan sobre el MISMO período, y el ROE que se publica es su producto —que
    es algebraicamente igual a resultado neto / patrimonio, porque los cocientes se cancelan—. Se
    calcula acá y no se deja al cliente para que la pantalla y una nota guardada muestren el mismo
    número con el mismo redondeo.

    Cada factor se suprime por separado si su base no da: con patrimonio negativo el apalancamiento no
    se calcula (daría un número negativo que se leería como "poca deuda"), y sin él tampoco hay
    producto. Un ROE parcial sería peor que ninguno.
    """

    if income is None or balance is None:
        return DupontBlock()

    net_margin = safe_pct(income.net_income, income.revenue)
    asset_turnover = safe_ratio(income.revenue, balance.total_assets)
    equity_multiplier = (
        safe_ratio(balance.total_assets, balance.total_equity)
        if (balance.total_equity or 0) > 0
        else None
    )
    roe_product: float | None = None
    if (
        net_margin is not None
        and asset_turnover is not None
        and equity_multiplier is not None
    ):
        roe_product = net_margin * asset_turnover * equity_multiplier

    return DupontBlock(
        net_margin_pct=net_margin,
        asset_turnover=asset_turnover,
        equity_multiplier=equity_multiplier,
        roe_pct=roe_product,
        criteria_source=CriteriaSource.RULE,
    )


# --- Banderas ------------------------------------------------------------------------------------
# Cada umbral está acá, con nombre, y se informa en la bandera que dispara. Son criterios del
# producto —opinables y discutibles— y no verdades contables: por eso se dejan a la vista en vez de
# esconderlos en un `if` dentro de la función.

_DEBT_TO_EQUITY_WARNING = 2.0
_DEBT_TO_EQUITY_CRITICAL = 4.0
_CURRENT_RATIO_WARNING = 1.0
_CURRENT_RATIO_STRONG = 2.0
_INTEREST_COVERAGE_WARNING = 3.0
_INTEREST_COVERAGE_CRITICAL = 1.5
_FCF_CONVERSION_WARNING = 60.0
_FCF_CONVERSION_STRONG = 100.0
_OPERATING_MARGIN_STRONG = 20.0
_REVENUE_GROWTH_STRONG = 15.0
_REVENUE_DECLINE_WARNING = -5.0


def es_number(value: float, *, decimals: int = 2) -> str:
    """Un número con la convención rioplatense: coma decimal y punto de miles.

    Se usa en TODO lo que el backend compone como prosa para el usuario —el detalle de una bandera,
    los supuestos del modelo—, porque esos textos se muestran tal cual. Un "3.67x" en medio de una
    frase en castellano se lee como tres mil seiscientos setenta, y "US$ 32,900 M" como treinta y dos
    con nueve.
    """

    # Se formatea con la convención inglesa y se dan vuelta los separadores: hacerlo en dos pasos con
    # un marcador intermedio evita el bug clásico de reemplazar en cadena y terminar con puntos donde
    # iban comas.
    formatted = f"{value:,.{decimals}f}"
    return formatted.replace(",", "\x00").replace(".", ",").replace("\x00", ".")


def es_millions(value: float) -> str:
    """Un monto en millones de dólares, con separadores rioplatenses."""

    return f"US$ {es_number(value / 1e6, decimals=0)} M"


def _flag(
    code: str,
    *,
    kind: FlagKind,
    severity: FlagSeverity,
    title: str,
    detail: str,
    metric_value: float | None = None,
    threshold: float | None = None,
) -> AnalysisFlag:
    return AnalysisFlag(
        code=code,
        kind=kind,
        severity=severity,
        title=title,
        detail=detail,
        metric_value=metric_value,
        threshold=threshold,
    )


def evaluate_flags(
    income: list[IncomeStatementBlock],
    balances: list[BalanceSheetBlock],
    cash_flows: list[CashFlowBlock],
) -> list[AnalysisFlag]:
    """Banderas rojas y verdes del último período disponible, con su umbral a la vista.

    Se evalúa el período MÁS RECIENTE y no un promedio: una bandera es una alerta sobre el estado
    actual, y promediar cinco años suavizaría exactamente lo que hay que ver. La única excepción es
    el crecimiento, que por definición necesita dos períodos.

    Devuelve la lista ordenada por gravedad para que el cliente no tenga que decidir qué mostrar
    primero — y para que dos pantallas distintas no elijan órdenes distintos.
    """

    flags: list[AnalysisFlag] = []
    latest_income = income[0] if income else None
    latest_balance = balances[0] if balances else None
    latest_cash = cash_flows[0] if cash_flows else None

    if latest_balance is not None:
        d_to_e = latest_balance.debt_to_equity
        if d_to_e is not None:
            if d_to_e >= _DEBT_TO_EQUITY_CRITICAL:
                flags.append(
                    _flag(
                        "DEBT_TO_EQUITY_CRITICAL",
                        kind=FlagKind.RED,
                        severity=FlagSeverity.CRITICAL,
                        title="Apalancamiento muy alto",
                        detail=(
                            f"Deuda/Patrimonio de {es_number(d_to_e)}x, por encima del "
                            f"umbral de {es_number(_DEBT_TO_EQUITY_CRITICAL)}x. La estructura de "
                            "capital depende del crédito para funcionar."
                        ),
                        metric_value=d_to_e,
                        threshold=_DEBT_TO_EQUITY_CRITICAL,
                    )
                )
            elif d_to_e >= _DEBT_TO_EQUITY_WARNING:
                flags.append(
                    _flag(
                        "DEBT_TO_EQUITY_HIGH",
                        kind=FlagKind.RED,
                        severity=FlagSeverity.WARNING,
                        title="Apalancamiento elevado",
                        detail=(
                            f"Deuda/Patrimonio de {es_number(d_to_e)}x, por encima del "
                            f"umbral de {es_number(_DEBT_TO_EQUITY_WARNING)}x."
                        ),
                        metric_value=d_to_e,
                        threshold=_DEBT_TO_EQUITY_WARNING,
                    )
                )

        if (latest_balance.total_equity or 0) < 0:
            flags.append(
                _flag(
                    "NEGATIVE_EQUITY",
                    kind=FlagKind.RED,
                    severity=FlagSeverity.CRITICAL,
                    title="Patrimonio negativo",
                    detail="El pasivo supera al activo. Los ratios que dividen por patrimonio no "
                    "se calculan porque su resultado no sería interpretable.",
                    metric_value=latest_balance.total_equity,
                )
            )

        current_ratio = latest_balance.current_ratio
        if current_ratio is not None:
            if current_ratio < _CURRENT_RATIO_WARNING:
                flags.append(
                    _flag(
                        "LOW_LIQUIDITY",
                        kind=FlagKind.RED,
                        severity=FlagSeverity.WARNING,
                        title="Liquidez corriente por debajo de 1",
                        detail=(
                            f"Liquidez corriente de {es_number(current_ratio)}x (umbral "
                            f"{es_number(_CURRENT_RATIO_WARNING)}x): el activo corriente no "
                            "alcanza a cubrir los vencimientos del año."
                        ),
                        metric_value=current_ratio,
                        threshold=_CURRENT_RATIO_WARNING,
                    )
                )
            elif current_ratio >= _CURRENT_RATIO_STRONG:
                flags.append(
                    _flag(
                        "STRONG_LIQUIDITY",
                        kind=FlagKind.GREEN,
                        severity=FlagSeverity.INFO,
                        title="Liquidez holgada",
                        detail=(
                            f"Liquidez corriente de {es_number(current_ratio)}x, por encima "
                            f"de {es_number(_CURRENT_RATIO_STRONG)}x."
                        ),
                        metric_value=current_ratio,
                        threshold=_CURRENT_RATIO_STRONG,
                    )
                )

        if latest_balance.net_debt is not None and latest_balance.net_debt < 0:
            flags.append(
                _flag(
                    "NET_CASH_POSITION",
                    kind=FlagKind.GREEN,
                    severity=FlagSeverity.INFO,
                    title="Caja neta positiva",
                    detail=(
                        "La caja supera a la deuda total en "
                        f"{es_millions(abs(latest_balance.net_debt))}."
                    ),
                    metric_value=latest_balance.net_debt,
                )
            )

    if latest_income is not None:
        coverage = safe_ratio(
            latest_income.operating_income,
            latest_income.interest_expense,
            # El piso de un millón no aplica a la cobertura: el gasto de intereses de una empresa
            # sin deuda puede ser de cientos de miles y el cociente sigue siendo informativo. Se usa
            # un piso chico solo para no dividir por un residuo.
            min_abs_denominator=1_000.0,
        )
        if coverage is not None:
            if coverage < _INTEREST_COVERAGE_CRITICAL:
                flags.append(
                    _flag(
                        "INTEREST_COVERAGE_CRITICAL",
                        kind=FlagKind.RED,
                        severity=FlagSeverity.CRITICAL,
                        title="Cobertura de intereses crítica",
                        detail=(
                            f"El resultado operativo cubre {es_number(coverage)}x el gasto "
                            f"de intereses (umbral "
                            f"{es_number(_INTEREST_COVERAGE_CRITICAL)}x)."
                        ),
                        metric_value=coverage,
                        threshold=_INTEREST_COVERAGE_CRITICAL,
                    )
                )
            elif coverage < _INTEREST_COVERAGE_WARNING:
                flags.append(
                    _flag(
                        "INTEREST_COVERAGE_LOW",
                        kind=FlagKind.RED,
                        severity=FlagSeverity.WARNING,
                        title="Cobertura de intereses ajustada",
                        detail=(
                            f"El resultado operativo cubre {es_number(coverage)}x el gasto "
                            f"de intereses (umbral "
                            f"{es_number(_INTEREST_COVERAGE_WARNING)}x)."
                        ),
                        metric_value=coverage,
                        threshold=_INTEREST_COVERAGE_WARNING,
                    )
                )

        net_margin = latest_income.net_margin_pct
        if net_margin is not None and net_margin < 0:
            flags.append(
                _flag(
                    "NET_LOSS",
                    kind=FlagKind.RED,
                    severity=FlagSeverity.CRITICAL,
                    title="Pérdida neta en el último período",
                    detail=f"Margen neto de {es_number(net_margin, decimals=1)}%.",
                    metric_value=net_margin,
                )
            )

        operating_margin = latest_income.operating_margin_pct
        if (
            operating_margin is not None
            and operating_margin >= _OPERATING_MARGIN_STRONG
        ):
            flags.append(
                _flag(
                    "STRONG_OPERATING_MARGIN",
                    kind=FlagKind.GREEN,
                    severity=FlagSeverity.INFO,
                    title="Margen operativo alto",
                    detail=(
                        f"Margen operativo de {es_number(operating_margin, decimals=1)}%, "
                        f"por encima de {es_number(_OPERATING_MARGIN_STRONG, decimals=1)}%."
                    ),
                    metric_value=operating_margin,
                    threshold=_OPERATING_MARGIN_STRONG,
                )
            )

    if len(income) >= 2:
        growth = change_pct(income[0].revenue, income[1].revenue)
        if growth is not None:
            if growth >= _REVENUE_GROWTH_STRONG:
                flags.append(
                    _flag(
                        "REVENUE_GROWTH_STRONG",
                        kind=FlagKind.GREEN,
                        severity=FlagSeverity.INFO,
                        title="Ingresos en expansión",
                        detail=(
                            f"Los ingresos crecieron {es_number(growth, decimals=1)}% contra "
                            f"el período anterior (umbral "
                            f"{es_number(_REVENUE_GROWTH_STRONG, decimals=1)}%)."
                        ),
                        metric_value=growth,
                        threshold=_REVENUE_GROWTH_STRONG,
                    )
                )
            elif growth <= _REVENUE_DECLINE_WARNING:
                flags.append(
                    _flag(
                        "REVENUE_DECLINE",
                        kind=FlagKind.RED,
                        severity=FlagSeverity.WARNING,
                        title="Ingresos en caída",
                        detail=(
                            f"Los ingresos cayeron {es_number(abs(growth), decimals=1)}% contra "
                            f"el período anterior (umbral "
                            f"{es_number(abs(_REVENUE_DECLINE_WARNING), decimals=1)}%)."
                        ),
                        metric_value=growth,
                        threshold=_REVENUE_DECLINE_WARNING,
                    )
                )

    if latest_cash is not None:
        if (latest_cash.free_cash_flow or 0) < 0:
            flags.append(
                _flag(
                    "NEGATIVE_FREE_CASH_FLOW",
                    kind=FlagKind.RED,
                    severity=FlagSeverity.WARNING,
                    title="Flujo de caja libre negativo",
                    detail=(
                        f"FCF de {es_millions(latest_cash.free_cash_flow or 0)}: la operación "
                        "no cubre las inversiones del período."
                    ),
                    metric_value=latest_cash.free_cash_flow,
                )
            )

        conversion = latest_cash.fcf_conversion_pct
        if conversion is not None:
            if conversion >= _FCF_CONVERSION_STRONG:
                flags.append(
                    _flag(
                        "STRONG_FCF_CONVERSION",
                        kind=FlagKind.GREEN,
                        severity=FlagSeverity.INFO,
                        title="La ganancia se convierte en caja",
                        detail=(
                            f"El FCF equivale al {es_number(conversion, decimals=0)}% del "
                            f"resultado neto (umbral "
                            f"{es_number(_FCF_CONVERSION_STRONG, decimals=0)}%)."
                        ),
                        metric_value=conversion,
                        threshold=_FCF_CONVERSION_STRONG,
                    )
                )
            elif conversion < _FCF_CONVERSION_WARNING:
                flags.append(
                    _flag(
                        "WEAK_FCF_CONVERSION",
                        kind=FlagKind.RED,
                        severity=FlagSeverity.WARNING,
                        title="La ganancia no se convierte en caja",
                        detail=(
                            f"El FCF equivale al {es_number(conversion, decimals=0)}% del "
                            f"resultado neto (umbral "
                            f"{es_number(_FCF_CONVERSION_WARNING, decimals=0)}%). Una diferencia "
                            "sostenida entre ganancia y caja es lo que el estado de resultados no "
                            "muestra."
                        ),
                        metric_value=conversion,
                        threshold=_FCF_CONVERSION_WARNING,
                    )
                )

    # Orden: primero lo más grave, y dentro de cada nivel las rojas antes que las verdes. Sin un
    # orden fijo, dos pantallas mostrarían la misma empresa con distinta primera impresión.
    severity_rank = {
        FlagSeverity.CRITICAL: 0,
        FlagSeverity.WARNING: 1,
        FlagSeverity.INFO: 2,
    }
    kind_rank = {FlagKind.RED: 0, FlagKind.GREEN: 1}
    flags.sort(key=lambda item: (severity_rank[item.severity], kind_rank[item.kind]))
    return flags


# --- Simulador -----------------------------------------------------------------------------------


def build_baseline(
    income: IncomeStatementBlock | None,
    balance: BalanceSheetBlock | None,
    cash_flow: CashFlowBlock | None,
    metrics: FinancialMetrics | None,
    *,
    period: StatementPeriod,
) -> ScenarioBaseline:
    """El punto de partida de la simulación.

    El precio de referencia se deriva de capitalización / acciones y NO de una cotización aparte: así
    el precio y el denominador del EPS salen del mismo par de números, y la variación del precio
    implícito significa algo.

    El múltiplo se calcula contra `model_eps` —el EPS que produce la cascada sin mover nada— y no
    contra el reportado. Ver `model_baseline_cascade`: es lo que hace que un escenario sin cambios
    devuelva exactamente el precio actual.
    """

    shares = income.weighted_shares_diluted if income else None
    market_cap: float | None = None
    if metrics is not None:
        if metrics.shares_outstanding.value is not None:
            shares = float(metrics.shares_outstanding.value)
        if metrics.market_cap.value is not None:
            market_cap = float(metrics.market_cap.value)

    eps = income.eps_diluted if income else None
    if eps is None and income is not None and shares:
        eps = safe_ratio(income.net_income, shares, min_abs_denominator=1.0)

    reference_price = safe_ratio(market_cap, shares, min_abs_denominator=1.0)

    total_debt = balance.total_debt if balance else None
    interest = income.interest_expense if income else None
    implied_rate = safe_pct(interest, total_debt) if (total_debt or 0) > 0 else None

    tax_rate = income.effective_tax_rate_pct if income else None
    if tax_rate is not None and not (
        _MIN_CREDIBLE_TAX_RATE_PCT <= tax_rate <= _MAX_CREDIBLE_TAX_RATE_PCT
    ):
        # Una tasa efectiva fuera de rango (un período con quebrantos, un crédito fiscal
        # extraordinario) se descarta en vez de propagarse: proyectar con ella multiplica el error.
        tax_rate = None

    baseline = ScenarioBaseline(
        period_end=income.period_end if income else None,
        period_label=income.period_label if income else None,
        period=period,
        revenue=income.revenue if income else None,
        ebitda=income.ebitda if income else None,
        ebitda_margin_pct=income.ebitda_margin_pct if income else None,
        depreciation_amortization=income.depreciation_amortization if income else None,
        interest_expense=interest,
        total_debt=total_debt,
        implied_interest_rate_pct=implied_rate,
        effective_tax_rate_pct=tax_rate,
        net_income=income.net_income if income else None,
        eps=eps,
        shares_outstanding=shares,
        free_cash_flow=cash_flow.free_cash_flow if cash_flow else None,
        reference_price=reference_price,
    )

    # El punto cero se calcula sobre el objeto ya armado —la cascada necesita el resto de la base para
    # correr— y se completa en un segundo paso. Hacerlo en dos partes es lo que evita duplicar acá la
    # fórmula de la cascada, que tiene que existir en un solo lugar.
    model_eps = model_baseline_cascade(baseline).eps
    multiple: float | None = None
    if (
        reference_price is not None
        and model_eps is not None
        and model_eps > 0
        and abs(model_eps) >= MIN_ABS_EPS_FOR_MULTIPLE
    ):
        multiple = reference_price / model_eps

    return baseline.model_copy(
        update={"model_eps": model_eps, "price_earnings_multiple": multiple}
    )


class _Cascade(NamedTuple):
    """Una corrida de la cascada. Existe para poder correrla DOS veces —una sin cambios y otra con el
    escenario— y comparar peras con peras.
    """

    revenue: float | None
    ebitda: float | None
    ebitda_margin_pct: float | None
    operating_income: float | None
    interest_expense: float | None
    net_income: float | None
    eps: float | None
    free_cash_flow: float | None


def run_cascade(
    baseline: ScenarioBaseline,
    *,
    growth_pct: float,
    margin_pct: float | None,
    interest_rate_pct: float | None,
) -> _Cascade:
    """La cascada determinística, en el orden del estado de resultados.

    Ingresos → EBITDA → resultado operativo → intereses → impuestos → resultado neto → EPS → FCF.
    Cada paso usa el valor proyectado del anterior. **Ninguna línea de esta función usa el modelo de
    lenguaje.**

    Lo que se mantiene constante viaja en `model_assumptions` de la respuesta: D&A, capex, capital de
    trabajo, acciones en circulación y stock de deuda. Un simulador que mueve todo a la vez no es un
    simulador, es una opinión con decimales.
    """

    revenue0 = baseline.revenue
    if revenue0 is None:
        return _Cascade(None, None, None, None, None, None, None, None)

    revenue = revenue0 * (1 + growth_pct / 100.0)
    ebitda = None if margin_pct is None else revenue * margin_pct / 100.0

    depreciation = baseline.depreciation_amortization or 0.0
    operating = None if ebitda is None else ebitda - depreciation

    # Intereses: la deuda se mantiene y se le aplica la tasa pedida. Sin deuda conocida o sin tasa
    # pedida, el gasto de intereses queda igual al base — no se inventa uno.
    interest = baseline.interest_expense
    if interest_rate_pct is not None and (baseline.total_debt or 0) > 0:
        interest = (baseline.total_debt or 0.0) * interest_rate_pct / 100.0

    tax_rate = (
        baseline.effective_tax_rate_pct
        if baseline.effective_tax_rate_pct is not None
        else _FALLBACK_TAX_RATE_PCT
    )

    net_income: float | None = None
    if operating is not None:
        pretax = operating - (interest or 0.0)
        # Solo se grava una ganancia. Con pérdida antes de impuestos, el resultado neto proyectado es
        # la pérdida sin tocar: aplicarle la tasa la reduciría, mostrando un quebranto como si el
        # fisco lo compensara en el mismo período.
        net_income = pretax * (1 - tax_rate / 100.0) if pretax > 0 else pretax

    eps = (
        safe_ratio(net_income, baseline.shares_outstanding, min_abs_denominator=1.0)
        if net_income is not None
        else None
    )

    # FCF: parte del FCF reportado y se mueve por el delta de EBITDA, de intereses y de impuestos
    # respecto del período base. Capex y capital de trabajo constantes, que es el supuesto declarado.
    free_cash_flow: float | None = None
    ebitda0 = baseline.ebitda
    if (
        baseline.free_cash_flow is not None
        and ebitda is not None
        and ebitda0 is not None
    ):
        interest0 = baseline.interest_expense or 0.0
        pretax0 = (ebitda0 - depreciation) - interest0
        tax0 = pretax0 * tax_rate / 100.0 if pretax0 > 0 else 0.0
        pretax_new = (ebitda - depreciation) - (interest or 0.0)
        tax_new = pretax_new * tax_rate / 100.0 if pretax_new > 0 else 0.0
        free_cash_flow = (
            baseline.free_cash_flow
            + (ebitda - ebitda0)
            - ((interest or 0.0) - interest0)
            - (tax_new - tax0)
        )

    return _Cascade(
        revenue=revenue,
        ebitda=ebitda,
        ebitda_margin_pct=margin_pct,
        operating_income=operating,
        interest_expense=interest,
        net_income=net_income,
        eps=eps,
        free_cash_flow=free_cash_flow,
    )


def scenario_margin_pct(
    baseline: ScenarioBaseline, variables: ScenarioVariables
) -> float | None:
    """El margen EBITDA que se va a usar.

    El pedido gana. Si no se pidió, se parte del margen base y la inflación le resta los puntos que
    no se traspasan a precios. Cuando el usuario fija un margen, la inflación NO se aplica encima: su
    margen ya es el supuesto, y descontarle inflación sería contradecir lo que pidió.
    """

    if variables.ebitda_margin_pct is not None:
        return variables.ebitda_margin_pct
    if baseline.ebitda_margin_pct is None:
        return None
    drag = (variables.inflation_pct or 0.0) * (1 - _COST_PASS_THROUGH)
    return baseline.ebitda_margin_pct - drag


def model_baseline_cascade(baseline: ScenarioBaseline) -> _Cascade:
    """La cascada corrida SIN mover nada: el punto cero del simulador.

    Es la referencia de todas las variaciones, y no el resultado reportado por la empresa, por una
    razón que se ve al probarlo: la cascada modela EBITDA → amortizaciones → intereses → impuestos, y
    una empresa real tiene además resultados no operativos y ajustes que el modelo no reproduce. Medir
    contra el reportado metía ese error de aproximación dentro del resultado, y un escenario **sin
    cambios** mostraba −1,3% de EPS — que un usuario lee como el efecto de algo.
    """

    return run_cascade(
        baseline,
        growth_pct=0.0,
        margin_pct=baseline.ebitda_margin_pct,
        interest_rate_pct=None,
    )


def project_scenario(
    baseline: ScenarioBaseline, variables: ScenarioVariables
) -> ScenarioProjection:
    """La proyección determinística de un escenario, con sus variaciones contra el punto cero."""

    if baseline.revenue is None:
        return ScenarioProjection()

    reference = model_baseline_cascade(baseline)
    scenario = run_cascade(
        baseline,
        growth_pct=variables.revenue_growth_pct or 0.0,
        margin_pct=scenario_margin_pct(baseline, variables),
        interest_rate_pct=variables.interest_rate_pct,
    )

    # El precio implícito escala el precio de referencia por la razón de EPS contra el punto cero.
    # Es lo mismo que "mantener el múltiplo", pero calculado así un escenario sin cambios devuelve
    # exactamente el precio actual en vez de arrastrar el error del modelo.
    implied_price: float | None = None
    if (
        baseline.reference_price is not None
        and scenario.eps is not None
        and reference.eps is not None
        and reference.eps > 0
        and abs(reference.eps) >= MIN_ABS_EPS_FOR_MULTIPLE
        and scenario.eps > 0
    ):
        implied_price = baseline.reference_price * (scenario.eps / reference.eps)

    return ScenarioProjection(
        revenue=scenario.revenue,
        ebitda=scenario.ebitda,
        ebitda_margin_pct=scenario.ebitda_margin_pct,
        operating_income=scenario.operating_income,
        interest_expense=scenario.interest_expense,
        net_income=scenario.net_income,
        eps=scenario.eps,
        free_cash_flow=scenario.free_cash_flow,
        revenue_change_pct=change_pct(scenario.revenue, reference.revenue),
        ebitda_change_pct=change_pct(scenario.ebitda, reference.ebitda),
        eps_change_pct=change_pct(scenario.eps, reference.eps),
        free_cash_flow_change_pct=change_pct(
            scenario.free_cash_flow, reference.free_cash_flow
        ),
        implied_price=implied_price,
        implied_price_change_pct=change_pct(implied_price, baseline.reference_price),
    )


def shift_variables(
    variables: ScenarioVariables, *, growth_pp: float, margin_pp: float
) -> ScenarioVariables:
    """Las variables del caso, corridas en puntos porcentuales.

    El margen se corre a partir del pedido SOLO si hay uno pedido: correr un margen que el usuario no
    fijó dejaría al caso pesimista con un margen explícito que él nunca eligió, y a la inflación sin
    efecto (porque un margen explícito la anula). Con margen sin fijar, el caso se diferencia solo por
    el crecimiento, que es exactamente lo que el usuario dejó abierto.
    """

    growth_base = variables.revenue_growth_pct or 0.0
    return ScenarioVariables(
        revenue_growth_pct=max(-100.0, min(500.0, growth_base + growth_pp)),
        ebitda_margin_pct=(
            None
            if variables.ebitda_margin_pct is None
            else max(-100.0, min(100.0, variables.ebitda_margin_pct + margin_pp))
        ),
        interest_rate_pct=variables.interest_rate_pct,
        inflation_pct=variables.inflation_pct,
        custom_event=variables.custom_event,
    )


def build_sensitivity(
    baseline: ScenarioBaseline, variables: ScenarioVariables
) -> list[SensitivityCase]:
    """La matriz Bear / Base / Bull.

    Los tres casos salen de la MISMA función de proyección con variables distintas: si el pesimista
    usara una fórmula propia, la comparación entre columnas dejaría de ser una comparación.
    """

    cases = [
        (
            ScenarioCase.BEAR,
            f"Pesimista (−{es_number(_CASE_GROWTH_SHIFT_PP, decimals=0)} pp de crecimiento)",
            shift_variables(
                variables,
                growth_pp=-_CASE_GROWTH_SHIFT_PP,
                margin_pp=-_CASE_MARGIN_SHIFT_PP,
            ),
        ),
        (ScenarioCase.BASE, "Base (lo que pediste)", variables),
        (
            ScenarioCase.BULL,
            f"Optimista (+{es_number(_CASE_GROWTH_SHIFT_PP, decimals=0)} pp de crecimiento)",
            shift_variables(
                variables,
                growth_pp=_CASE_GROWTH_SHIFT_PP,
                margin_pp=_CASE_MARGIN_SHIFT_PP,
            ),
        ),
    ]

    return [
        SensitivityCase(
            case=case,
            label=label,
            variables=case_variables,
            projection=project_scenario(baseline, case_variables),
        )
        for case, label, case_variables in cases
    ]


def build_model_assumptions(
    baseline: ScenarioBaseline, variables: ScenarioVariables
) -> list[str]:
    """Los supuestos del modelo, en castellano y listos para mostrar.

    Se arman en el servidor y no en el cliente porque son parte del resultado: una proyección sin sus
    supuestos tiene la autoridad de un pronóstico y la solidez de una cuenta al margen. Cada línea
    dice qué se hizo con un número concreto, no una generalidad.
    """

    assumptions: list[str] = [
        (
            "El crecimiento de ingresos que ingresás se toma como NOMINAL: la inflación no se le "
            "suma encima para no contar dos veces el mismo aumento."
        ),
        (
            "Se mantienen constantes las amortizaciones, el capex, el capital de trabajo, la "
            "cantidad de acciones y el stock de deuda."
        ),
    ]

    if variables.ebitda_margin_pct is not None:
        assumptions.append(
            f"El margen EBITDA se fija en {es_number(variables.ebitda_margin_pct, decimals=1)}%, "
            "que es el que pediste. La inflación no le resta puntos encima: tu margen ya es el "
            "supuesto."
        )
    elif variables.inflation_pct:
        drag = variables.inflation_pct * (1 - _COST_PASS_THROUGH)
        assumptions.append(
            f"La inflación de {es_number(variables.inflation_pct, decimals=1)}% le resta "
            f"{es_number(drag)} puntos al margen EBITDA, asumiendo que se traspasa a precios el "
            f"{es_number(_COST_PASS_THROUGH * 100, decimals=0)}% del aumento de costos. Ese "
            "traspaso es un supuesto del modelo, no una medición."
        )

    if variables.interest_rate_pct is not None:
        if (baseline.total_debt or 0) > 0:
            base_rate = (
                f"{es_number(baseline.implied_interest_rate_pct)}%"
                if baseline.implied_interest_rate_pct is not None
                else "no calculable"
            )
            assumptions.append(
                f"La tasa de {es_number(variables.interest_rate_pct)}% se aplica sobre la deuda "
                f"total del último balance ({es_millions(baseline.total_debt or 0)}). Tasa "
                f"implícita del período base: {base_rate}."
            )
        else:
            assumptions.append(
                "La tasa de interés que pediste no cambia nada: el último balance no muestra deuda "
                "sobre la cual aplicarla."
            )

    if baseline.effective_tax_rate_pct is not None:
        assumptions.append(
            "Se grava con la tasa efectiva del período base "
            f"({es_number(baseline.effective_tax_rate_pct, decimals=1)}%)."
        )
    else:
        assumptions.append(
            "No se pudo calcular la tasa efectiva del período base, así que se usa la "
            f"estatutaria de {es_number(_FALLBACK_TAX_RATE_PCT, decimals=0)}%."
        )

    if baseline.price_earnings_multiple is not None:
        assumptions.append(
            "El precio implícito mantiene el múltiplo de "
            f"{es_number(baseline.price_earnings_multiple, decimals=1)}x y mueve solo el EPS. Es "
            "una convención para medir sensibilidad, NO un precio objetivo."
        )

    if baseline.model_eps is not None and baseline.eps is not None:
        assumptions.append(
            "Las variaciones se miden contra el punto cero del modelo (EPS "
            f"{es_number(baseline.model_eps)}), no contra el EPS reportado de "
            f"{es_number(baseline.eps)}: la cascada no reproduce los resultados no operativos ni los "
            "ajustes de la empresa, y comparar contra el reportado metería ese error dentro del "
            "resultado del escenario."
        )

    if variables.custom_event:
        assumptions.append(
            "El evento que describiste no entra en ninguna fórmula: su efecto se explica en el "
            "texto, porque cuantificarlo sería inventar un coeficiente."
        )

    return assumptions


def valuation_note(baseline: ScenarioBaseline) -> tuple[ValuationBasis, str | None]:
    """Cómo se derivó el precio, y el motivo si no se pudo.

    Los tres motivos posibles se distinguen porque se arreglan distinto: sin precio de referencia
    falta el proveedor, con EPS negativo no hay múltiplo que sostener, y con EPS ínfimo el múltiplo
    existe pero amplifica cualquier variación hasta el absurdo.
    """

    if baseline.reference_price is None:
        return (
            ValuationBasis.NOT_APPLICABLE,
            (
                "Sin precio de referencia (falta la capitalización o la cantidad de acciones), así "
                "que no se puede estimar una variación en la cotización."
            ),
        )
    if baseline.model_eps is None:
        return (
            ValuationBasis.NOT_APPLICABLE,
            "Sin EPS en el período base no hay múltiplo que mantener.",
        )
    if baseline.model_eps <= 0:
        return (
            ValuationBasis.NOT_APPLICABLE,
            (
                "El EPS del período base no es positivo: un múltiplo precio/ganancias sobre una "
                "pérdida no tiene interpretación, así que no se estima variación de precio."
            ),
        )
    if abs(baseline.model_eps) < MIN_ABS_EPS_FOR_MULTIPLE:
        return (
            ValuationBasis.NOT_APPLICABLE,
            (
                "El EPS del período base es demasiado cercano a cero: el múltiplo implícito sería "
                "tan grande que cualquier variación daría un precio absurdo."
            ),
        )
    if baseline.price_earnings_multiple is None:
        return (
            ValuationBasis.NOT_APPLICABLE,
            "No se pudo calcular el múltiplo precio/ganancias del período base.",
        )
    return (
        ValuationBasis.PE_MULTIPLE_HELD,
        "El precio implícito mantiene constante el múltiplo precio/ganancias actual y mueve el EPS.",
    )


# --- Salida del modelo ---------------------------------------------------------------------------


class _LLMNarrative(BaseModel):
    """Lo único que se le pide al modelo: prosa.

    Deliberadamente sin ningún campo numérico. Si el esquema tuviera un `eps_proyectado`, el modelo
    lo llenaría con algo parecido a lo que vio y ese número competiría con el calculado — y en algún
    momento alguna pantalla mostraría el del modelo.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    narrative: str


_NARRATIVE_SCHEMA: dict[str, Any] = {
    "type": "OBJECT",
    "properties": {"narrative": {"type": "STRING"}},
    "required": ["narrative"],
}


def _load_prompt(path: Path, fallback: str) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        # Un prompt faltante degrada a uno mínimo pero suficiente en vez de tumbar el arranque de la
        # app: el módulo entero quedaría inalcanzable por un archivo que no se copió.
        logger.warning("ai_lab_prompt_missing", extra={"prompt_path": str(path)})
        return fallback


_ANALYSIS_FALLBACK_PROMPT = (
    "Sos un analista contable. Recibís estados contables YA CALCULADOS y explicás qué significan "
    "en castellano rioplatense. No inventes ni recalcules cifras: usá solo las que recibís."
)
_SCENARIO_FALLBACK_PROMPT = (
    "Sos un analista financiero. Recibís una simulación YA CALCULADA y explicás qué implica en "
    "castellano rioplatense. No inventes ni recalcules cifras: usá solo las que recibís."
)


# --- Servicio ------------------------------------------------------------------------------------


class AiLabService:
    """Los dos clientes son opcionales y `None` es un estado válido.

    Sin FMP no hay estados contables y las dos vistas lo declaran. Sin Gemini, el análisis conserva
    todos sus números y sus banderas: lo único que falta es la prosa, y eso se informa aparte.
    """

    def __init__(
        self,
        *,
        fmp_client: FMPClient | None = None,
        gemini_client: GeminiClient | None = None,
        statements_ttl_seconds: float = 21600.0,
        metrics_ttl_seconds: float = 3600.0,
        statement_periods: int = MAX_STATEMENT_PERIODS,
        analysis_prompt: str | None = None,
        scenario_prompt: str | None = None,
    ) -> None:
        self._fmp = fmp_client
        self._gemini = gemini_client
        self._statement_periods = max(2, min(statement_periods, MAX_STATEMENT_PERIODS))

        # Dos TTL distintos porque los datos envejecen distinto: un estado contable publicado no
        # cambia hasta el próximo reporte (horas de caché no arriesgan nada) y la capitalización se
        # mueve con el precio durante la rueda.
        self._statements_cache: TtlCache[FinancialStatements] = TtlCache(
            ttl_seconds=statements_ttl_seconds
        )
        self._metrics_cache: TtlCache[FinancialMetrics] = TtlCache(
            ttl_seconds=metrics_ttl_seconds
        )

        self._analysis_prompt = analysis_prompt or _load_prompt(
            _ANALYSIS_PROMPT_PATH, _ANALYSIS_FALLBACK_PROMPT
        )
        self._scenario_prompt = scenario_prompt or _load_prompt(
            _SCENARIO_PROMPT_PATH, _SCENARIO_FALLBACK_PROMPT
        )

    # --- Datos ----------------------------------------------------------------------------

    async def _load_statements(
        self, ticker: str, period: StatementPeriod
    ) -> tuple[FinancialStatements | None, str | None, bool]:
        """Los estados contables del símbolo. Devuelve (estados, motivo, servido_de_caché).

        Un fallo del proveedor NO se cachea: se recupera en segundos, y guardarlo convertiría un
        hipo de red en seis horas de "esta empresa no publica estados".
        """

        if (fmp := self._fmp) is None:
            return None, REASON_NO_FMP, False

        key = f"{ticker}:{period.value}"
        cached = self._statements_cache.get(key)
        if cached is not None:
            return cached, None, True

        async with self._statements_cache.lock_for(key):
            cached = self._statements_cache.get(key)
            if cached is not None:
                return cached, None, True

            try:
                statements, status = await fmp.get_financial_statements(
                    ticker,
                    period="annual" if period is StatementPeriod.ANNUAL else "quarter",
                    limit=self._statement_periods,
                )
            except Exception as exc:  # noqa: BLE001 — el cliente degrada sus errores de proveedor
                # sin lanzar; esto cubre un bug inesperado y se registra en vez de tumbar la vista.
                logger.warning(
                    "ai_lab_statements_failed",
                    extra={"ai_lab_ticker": ticker, "error": str(exc)},
                )
                return None, REASON_FMP_FAILED, False

            if status != DataStatus.OK:
                return None, REASON_FMP_FAILED, False

            self._statements_cache.set(key, statements)
            return statements, None, False

    async def _load_metrics(self, ticker: str) -> FinancialMetrics | None:
        """Capitalización y acciones, para el precio de referencia. Su ausencia no degrada el
        análisis: solo deja la simulación sin precio implícito, que se declara aparte.
        """

        if (fmp := self._fmp) is None:
            return None

        cached = self._metrics_cache.get(ticker)
        if cached is not None:
            return cached

        async with self._metrics_cache.lock_for(ticker):
            cached = self._metrics_cache.get(ticker)
            if cached is not None:
                return cached
            try:
                metrics = await fmp.get_financial_metrics(ticker)
            except Exception as exc:  # noqa: BLE001 — ídem: se degrada este bloque y nada más.
                logger.warning(
                    "ai_lab_metrics_failed",
                    extra={"ai_lab_ticker": ticker, "error": str(exc)},
                )
                return None
            self._metrics_cache.set(ticker, metrics)
            return metrics

    # --- Análisis contable -----------------------------------------------------------------

    async def analyze(
        self, request: FinancialAnalysisRequest
    ) -> FinancialAnalysisResponse:
        """Diagnóstico contable, con o sin pregunta."""

        ticker = request.normalized_ticker
        now = datetime.now(timezone.utc)

        statements, reason, from_cache = await self._load_statements(
            ticker, request.period
        )

        if statements is None:
            return FinancialAnalysisResponse(
                ticker=ticker,
                period=request.period,
                generated_at=now,
                history=list(request.history),
                availability=DataAvailability.UNAVAILABLE,
                degradation_reason=reason,
                narrative_degradation_reason=None,
            )

        income = [build_income_block(row) for row in statements.income]
        balances = [build_balance_block(row) for row in statements.balance]

        # El flujo de caja se cruza con el estado de resultados del mismo período POR FECHA, no por
        # posición: los tres endpoints pueden traer distinta cantidad de filas, y aparearlos por
        # índice mezclaría el FCF de un año con la ganancia de otro.
        income_by_date = {
            block.period_end: block for block in income if block.period_end is not None
        }
        cash_flows: list[CashFlowBlock] = []
        for row in statements.cash_flow:
            row_date = _parse_date(_text(row, _PERIOD_END_KEYS))
            matched = income_by_date.get(row_date) if row_date else None
            cash_flows.append(
                build_cash_flow_block(
                    row,
                    revenue=matched.revenue if matched else None,
                    net_income=matched.net_income if matched else None,
                )
            )

        flags = evaluate_flags(income, balances, cash_flows)
        dupont = build_dupont(
            income[0] if income else None, balances[0] if balances else None
        )

        has_data = bool(income or balances or cash_flows)
        narrative, narrative_reason = await self._analysis_narrative(
            ticker=ticker,
            period=request.period,
            income=income,
            balances=balances,
            cash_flows=cash_flows,
            dupont=dupont,
            flags=flags,
            question=request.question,
            history=request.history,
            skip=not has_data,
        )

        history = _extend_history(request.history, request.question, narrative)

        return FinancialAnalysisResponse(
            ticker=ticker,
            company_name=None,
            period=request.period,
            generated_at=now,
            income_statements=income,
            balance_sheets=balances,
            cash_flows=cash_flows,
            dupont=dupont,
            flags=flags,
            narrative=narrative,
            narrative_source=(
                NarrativeSource.LLM if narrative is not None else NarrativeSource.NONE
            ),
            history=history,
            # Con el proveedor sano y sin estados, la respuesta es AVAILABLE con listas vacías y el
            # motivo aparte: "esta empresa no publica estados en el proveedor" es un dato, no una
            # falla del sistema.
            availability=(
                DataAvailability.AVAILABLE if has_data else DataAvailability.UNAVAILABLE
            ),
            degradation_reason=None if has_data else REASON_NO_STATEMENTS,
            narrative_degradation_reason=narrative_reason,
            served_from_cache=from_cache,
        )

    async def _analysis_narrative(
        self,
        *,
        ticker: str,
        period: StatementPeriod,
        income: list[IncomeStatementBlock],
        balances: list[BalanceSheetBlock],
        cash_flows: list[CashFlowBlock],
        dupont: DupontBlock,
        flags: list[AnalysisFlag],
        question: str | None,
        history: list[ConversationTurn],
        skip: bool,
    ) -> tuple[str | None, str | None]:
        """La lectura escrita. Devuelve (narrativa, motivo_si_falta).

        No se le pide nada al modelo cuando no hay datos: sería pedirle que escriba sobre un conjunto
        vacío, y lo que devolvería es exactamente la clase de texto plausible y sin respaldo que este
        módulo evita.
        """

        if skip:
            return None, None
        if (gemini := self._gemini) is None:
            return None, REASON_NO_GEMINI

        user_content = build_analysis_prompt(
            ticker=ticker,
            period=period,
            income=income,
            balances=balances,
            cash_flows=cash_flows,
            dupont=dupont,
            flags=flags,
            question=question,
            history=history,
        )

        result = await gemini.generate_structured_json(
            system_instruction=self._analysis_prompt,
            user_content=user_content,
            response_schema=_NARRATIVE_SCHEMA,
        )

        if result.status != DataStatus.OK or result.raw_json_text is None:
            logger.warning(
                "ai_lab_analysis_llm_failed", extra={"ai_lab_ticker": ticker}
            )
            return None, REASON_GEMINI_FAILED

        narrative = _parse_narrative(result.raw_json_text)
        if narrative is None:
            logger.warning(
                "ai_lab_analysis_llm_invalid", extra={"ai_lab_ticker": ticker}
            )
            return None, REASON_GEMINI_FAILED
        return narrative, None

    # --- Simulador -------------------------------------------------------------------------

    async def simulate(
        self, request: ScenarioSimulationRequest
    ) -> ScenarioSimulationResult:
        """Simulación "qué pasaría si" sobre el último período disponible."""

        ticker = request.normalized_ticker
        now = datetime.now(timezone.utc)
        variables = request.variables

        statements_result, metrics = await asyncio.gather(
            self._load_statements(ticker, request.period),
            self._load_metrics(ticker),
        )
        statements, reason, from_cache = statements_result

        if statements is None:
            return ScenarioSimulationResult(
                ticker=ticker,
                generated_at=now,
                applied_variables=variables,
                custom_event=variables.custom_event,
                availability=DataAvailability.UNAVAILABLE,
                degradation_reason=reason,
            )

        income = build_income_block(statements.income[0]) if statements.income else None
        balance = (
            build_balance_block(statements.balance[0]) if statements.balance else None
        )
        cash_flow = (
            build_cash_flow_block(
                statements.cash_flow[0],
                revenue=income.revenue if income else None,
                net_income=income.net_income if income else None,
            )
            if statements.cash_flow
            else None
        )

        baseline = build_baseline(
            income, balance, cash_flow, metrics, period=request.period
        )

        # Sin ingresos ni resultado neto no hay cascada que proyectar. Se declara en vez de devolver
        # una proyección de ceros, que se leería como "esta empresa no va a facturar nada".
        if baseline.revenue is None or baseline.net_income is None:
            return ScenarioSimulationResult(
                ticker=ticker,
                generated_at=now,
                baseline=baseline,
                applied_variables=variables,
                custom_event=variables.custom_event,
                availability=DataAvailability.UNAVAILABLE,
                degradation_reason=REASON_NO_BASELINE,
                served_from_cache=from_cache,
            )

        projection = project_scenario(baseline, variables)
        sensitivity = build_sensitivity(baseline, variables)
        basis, note = valuation_note(baseline)
        assumptions = build_model_assumptions(baseline, variables)

        narrative, narrative_reason = await self._scenario_narrative(
            ticker=ticker,
            baseline=baseline,
            variables=variables,
            projection=projection,
            sensitivity=sensitivity,
            basis=basis,
            assumptions=assumptions,
        )

        return ScenarioSimulationResult(
            ticker=ticker,
            generated_at=now,
            baseline=baseline,
            applied_variables=variables,
            projection=projection,
            sensitivity=sensitivity,
            valuation_basis=basis,
            valuation_note=note,
            model_assumptions=assumptions,
            custom_event=variables.custom_event,
            custom_event_is_qualitative=True,
            narrative=narrative,
            narrative_source=(
                NarrativeSource.LLM if narrative is not None else NarrativeSource.NONE
            ),
            availability=DataAvailability.AVAILABLE,
            degradation_reason=None,
            narrative_degradation_reason=narrative_reason,
            served_from_cache=from_cache,
        )

    async def _scenario_narrative(
        self,
        *,
        ticker: str,
        baseline: ScenarioBaseline,
        variables: ScenarioVariables,
        projection: ScenarioProjection,
        sensitivity: list[SensitivityCase],
        basis: ValuationBasis,
        assumptions: list[str],
    ) -> tuple[str | None, str | None]:
        if (gemini := self._gemini) is None:
            return None, REASON_NO_GEMINI

        result = await gemini.generate_structured_json(
            system_instruction=self._scenario_prompt,
            user_content=build_scenario_prompt(
                ticker=ticker,
                baseline=baseline,
                variables=variables,
                projection=projection,
                sensitivity=sensitivity,
                basis=basis,
                assumptions=assumptions,
            ),
            response_schema=_NARRATIVE_SCHEMA,
        )

        if result.status != DataStatus.OK or result.raw_json_text is None:
            logger.warning(
                "ai_lab_scenario_llm_failed", extra={"ai_lab_ticker": ticker}
            )
            return None, REASON_GEMINI_FAILED

        narrative = _parse_narrative(result.raw_json_text)
        if narrative is None:
            logger.warning(
                "ai_lab_scenario_llm_invalid", extra={"ai_lab_ticker": ticker}
            )
            return None, REASON_GEMINI_FAILED
        return narrative, None


# --- Prompts -------------------------------------------------------------------------------------


def _fmt(value: float | None, *, unit: str = "", decimals: int = 2) -> str:
    """Un número para el prompt, o "no disponible".

    El texto explícito y no un `null`: el modelo tiene que leer la ausencia como una instrucción de
    no hablar de ese dato, y un `null` suelto en medio de una lista es fácil de saltear.
    """

    if value is None:
        return "no disponible"
    return f"{value:,.{decimals}f}{unit}"


def _millions(value: float | None) -> str:
    if value is None:
        return "no disponible"
    return f"US$ {value / 1e6:,.0f} M"


def build_analysis_prompt(
    *,
    ticker: str,
    period: StatementPeriod,
    income: list[IncomeStatementBlock],
    balances: list[BalanceSheetBlock],
    cash_flows: list[CashFlowBlock],
    dupont: DupontBlock,
    flags: list[AnalysisFlag],
    question: str | None,
    history: list[ConversationTurn],
) -> str:
    """El contexto del diagnóstico, con TODOS los números ya calculados.

    Los datos van etiquetados y en unidades explícitas para que el modelo no tenga que convertir
    nada: cada conversión que le dejáramos hacer es una oportunidad de equivocarse en un número que
    después se muestra como si lo hubiéramos calculado nosotros.
    """

    lines = [
        f"<empresa>{ticker}</empresa>",
        f"<periodicidad>{'anual' if period is StatementPeriod.ANNUAL else 'trimestral'}</periodicidad>",
        "<estado_de_resultados>",
    ]

    for block in income:
        lines.append(
            f"- {block.period_label or block.period_end or 'período'}: "
            f"ingresos {_millions(block.revenue)}, "
            f"margen bruto {_fmt(block.gross_margin_pct, unit='%', decimals=1)}, "
            f"margen operativo {_fmt(block.operating_margin_pct, unit='%', decimals=1)}, "
            f"EBITDA {_millions(block.ebitda)}"
            f"{' (reconstruido como operativo + amortizaciones)' if block.ebitda_is_derived else ''}, "
            f"margen neto {_fmt(block.net_margin_pct, unit='%', decimals=1)}, "
            f"EPS diluido {_fmt(block.eps_diluted)}"
        )
    if not income:
        lines.append("- Sin estado de resultados disponible.")
    lines.append("</estado_de_resultados>")

    lines.append("<balance_general>")
    for sheet in balances:
        lines.append(
            f"- {sheet.period_label or sheet.period_end or 'período'}: "
            f"activo {_millions(sheet.total_assets)}, "
            f"pasivo {_millions(sheet.total_liabilities)}, "
            f"patrimonio {_millions(sheet.total_equity)}, "
            f"deuda total {_millions(sheet.total_debt)}, "
            f"deuda neta {_millions(sheet.net_debt)}, "
            f"liquidez corriente {_fmt(sheet.current_ratio, unit='x')}, "
            f"deuda/patrimonio {_fmt(sheet.debt_to_equity, unit='x')}"
        )
    if not balances:
        lines.append("- Sin balance general disponible.")
    lines.append("</balance_general>")

    lines.append("<flujo_de_caja>")
    for flow in cash_flows:
        lines.append(
            f"- {flow.period_label or flow.period_end or 'período'}: "
            f"caja operativa {_millions(flow.operating_cash_flow)}, "
            f"capex {_millions(flow.capital_expenditure)}, "
            f"FCF {_millions(flow.free_cash_flow)}, "
            f"conversión FCF/resultado neto "
            f"{_fmt(flow.fcf_conversion_pct, unit='%', decimals=0)}"
        )
    if not cash_flows:
        lines.append("- Sin flujo de caja disponible.")
    lines.append("</flujo_de_caja>")

    lines.append("<dupont>")
    if dupont.is_complete:
        lines.append(
            f"ROE descompuesto: margen neto {_fmt(dupont.net_margin_pct, unit='%', decimals=1)} × "
            f"rotación de activos {_fmt(dupont.asset_turnover, unit='x')} × "
            f"apalancamiento {_fmt(dupont.equity_multiplier, unit='x')} = "
            f"{_fmt(dupont.roe_pct, unit='%', decimals=1)}."
        )
    else:
        lines.append(
            "No se pudo descomponer el ROE: faltan líneas del balance o de resultados."
        )
    lines.append("</dupont>")

    lines.append("<banderas_calculadas_en_codigo>")
    for flag in flags:
        lines.append(
            f"- [{flag.kind.value}/{flag.severity.value}] {flag.title}: {flag.detail}"
        )
    if not flags:
        lines.append("- Ninguna bandera se disparó con los umbrales del producto.")
    lines.append("</banderas_calculadas_en_codigo>")

    if history:
        lines.append("<conversacion_previa>")
        for turn in history[-MAX_HISTORY_TURNS:]:
            speaker = "Usuario" if turn.role is ConversationRole.USER else "Analista"
            lines.append(f"{speaker}: {turn.content}")
        lines.append("</conversacion_previa>")

    if question:
        lines.append(f"<pregunta>{question}</pregunta>")
    else:
        lines.append(
            "<pregunta>No hay una pregunta puntual: hacé el diagnóstico general de la "
            "situación contable.</pregunta>"
        )

    return "\n".join(lines)


def build_scenario_prompt(
    *,
    ticker: str,
    baseline: ScenarioBaseline,
    variables: ScenarioVariables,
    projection: ScenarioProjection,
    sensitivity: list[SensitivityCase],
    basis: ValuationBasis,
    assumptions: list[str],
) -> str:
    """El contexto del escenario: base, variables, resultados YA calculados y los supuestos.

    El prompt le manda al modelo los tres casos completos y le prohíbe recalcular: su trabajo es
    explicar por qué el EPS se mueve lo que se mueve y qué implicaría el evento descrito, no volver a
    hacer la cuenta.
    """

    lines = [
        f"<empresa>{ticker}</empresa>",
        "<punto_de_partida>",
        f"Período base: {baseline.period_label or baseline.period_end or 'último disponible'}.",
        (
            f"Ingresos {_millions(baseline.revenue)}, "
            f"EBITDA {_millions(baseline.ebitda)} "
            f"(margen {_fmt(baseline.ebitda_margin_pct, unit='%', decimals=1)}), "
            f"resultado neto {_millions(baseline.net_income)}, "
            f"EPS {_fmt(baseline.eps)}, "
            f"FCF {_millions(baseline.free_cash_flow)}."
        ),
        (
            f"Deuda total {_millions(baseline.total_debt)} con una tasa implícita de "
            f"{_fmt(baseline.implied_interest_rate_pct, unit='%')}. Tasa impositiva efectiva "
            f"{_fmt(baseline.effective_tax_rate_pct, unit='%', decimals=1)}."
        ),
        (
            f"Precio de referencia {_fmt(baseline.reference_price, unit=' USD')}, "
            f"múltiplo P/E {_fmt(baseline.price_earnings_multiple, unit='x', decimals=1)}."
        ),
        "</punto_de_partida>",
        "<variables_del_escenario>",
        f"Crecimiento de ingresos: {_fmt(variables.revenue_growth_pct, unit='%', decimals=1)}.",
        f"Margen EBITDA pedido: {_fmt(variables.ebitda_margin_pct, unit='%', decimals=1)}.",
        f"Tasa de interés: {_fmt(variables.interest_rate_pct, unit='%')}.",
        f"Inflación: {_fmt(variables.inflation_pct, unit='%', decimals=1)}.",
        "</variables_del_escenario>",
    ]

    if variables.custom_event:
        lines.extend(
            [
                "<evento_descrito_por_el_usuario>",
                variables.custom_event,
                "</evento_descrito_por_el_usuario>",
                "<regla_del_evento>",
                (
                    "Este evento NO se cuantificó: no movió ninguno de los números de abajo. "
                    "Explicá qué líneas del negocio tocaría y en qué dirección, y decí "
                    "explícitamente que su magnitud no está calculada. No inventes un porcentaje "
                    "de impacto."
                ),
                "</regla_del_evento>",
            ]
        )

    lines.append("<proyeccion_calculada_en_codigo>")
    lines.append(
        f"Caso base: ingresos {_millions(projection.revenue)} "
        f"({_fmt(projection.revenue_change_pct, unit='%', decimals=1)}), "
        f"EBITDA {_millions(projection.ebitda)} "
        f"({_fmt(projection.ebitda_change_pct, unit='%', decimals=1)}), "
        f"EPS {_fmt(projection.eps)} "
        f"({_fmt(projection.eps_change_pct, unit='%', decimals=1)}), "
        f"FCF {_millions(projection.free_cash_flow)}."
    )
    if projection.implied_price is not None:
        lines.append(
            f"Precio implícito {_fmt(projection.implied_price, unit=' USD')} "
            f"({_fmt(projection.implied_price_change_pct, unit='%', decimals=1)})."
        )
    else:
        lines.append(
            "Sin precio implícito calculable: no hables de precio objetivo ni estimes una variación "
            "de cotización."
        )
    lines.append("</proyeccion_calculada_en_codigo>")

    lines.append("<matriz_de_sensibilidad>")
    for case in sensitivity:
        lines.append(
            f"- {case.case.value} ({case.label}): "
            f"EPS {_fmt(case.projection.eps)} "
            f"({_fmt(case.projection.eps_change_pct, unit='%', decimals=1)}), "
            f"precio implícito {_fmt(case.projection.implied_price, unit=' USD')}."
        )
    lines.append("</matriz_de_sensibilidad>")

    lines.append("<supuestos_del_modelo>")
    lines.extend(f"- {item}" for item in assumptions)
    if basis is ValuationBasis.NOT_APPLICABLE:
        lines.append("- No hay base de valuación: no menciones precios proyectados.")
    lines.append("</supuestos_del_modelo>")

    return "\n".join(lines)


def _parse_narrative(raw_json_text: str) -> str | None:
    """La prosa del modelo, o `None` si la respuesta no se puede leer.

    `strict=False` solo en esta frontera JSON, igual que en el resto de la app: el modelo puede
    mandar un número donde el esquema pide texto, y eso no debería tirar la respuesta entera.
    """

    try:
        parsed = json.loads(raw_json_text)
        narrative = _LLMNarrative.model_validate(parsed, strict=False)
    except (json.JSONDecodeError, ValidationError):
        return None
    text = narrative.narrative.strip()
    return text or None


def _extend_history(
    history: list[ConversationTurn], question: str | None, narrative: str | None
) -> list[ConversationTurn]:
    """El hilo con este turno agregado.

    El turno del usuario se agrega SOLO si hubo pregunta, y el del analista solo si hubo respuesta:
    un hilo con una pregunta sin respuesta invitaría al cliente a mandarla de nuevo en el próximo
    request, duplicándola.

    El recorte deja los turnos MÁS RECIENTES: en una conversación contable, el contexto que importa
    es el de las últimas preguntas, no el del saludo inicial.
    """

    turns = list(history)
    if not question:
        # La lectura general del diagnóstico NO es un turno de conversación: ya se devuelve en
        # `narrative` y la pantalla la muestra como el informe del activo. Meterla en el hilo la
        # mostraba dos veces —una como informe y otra como si el analista hubiera contestado algo—,
        # y además viajaba de vuelta en el próximo request como una respuesta sin pregunta.
        return turns[-MAX_HISTORY_TURNS:]

    turns.append(
        ConversationTurn(role=ConversationRole.USER, content=question[:MAX_TURN_CHARS])
    )
    if narrative:
        turns.append(
            ConversationTurn(
                role=ConversationRole.ASSISTANT, content=narrative[:MAX_TURN_CHARS]
            )
        )
    return turns[-MAX_HISTORY_TURNS:]
