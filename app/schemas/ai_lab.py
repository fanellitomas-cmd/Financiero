"""Schemas de `/api/v1/ai-lab/*` — el Laboratorio Financiero y el Simulador de Escenarios.

Dos capacidades sobre los estados contables de una empresa: un diagnóstico contable conversacional
(balance, resultados, DuPont, flujo de caja, banderas) y un simulador "qué pasaría si" que proyecta
métricas a partir de variables macro/operativas.

**Las cuatro reglas de contrato que este módulo existe para hacer cumplir:**

  1. **Todo número sale de una fórmula, nunca del modelo.** Los márgenes, la descomposición DuPont,
     las banderas, la proyección y el precio implícito se calculan en código. Gemini interviene en un
     solo lugar y solo para REDACTAR: la explicación del escenario. Cada respuesta declara eso en
     `narrative_source`, para que el cliente pueda presentar la prosa como interpretación y las
     cifras como cálculo.
  2. **Una simulación declara su modelo.** `model_assumptions` viaja siempre y en castellano: qué se
     mantuvo constante, con qué tasa se gravó, qué múltiplo se usó para el precio. Una proyección sin
     sus supuestos es un número con la autoridad de un pronóstico y la solidez de una cuenta al
     margen.
  3. **El precio implícito NO es un precio objetivo.** Sale de mantener el múltiplo actual y mover el
     EPS; `valuation_basis` lo dice explícitamente. Si el EPS base no es positivo, no hay múltiplo
     que sostener y el precio implícito viaja en `null` con su motivo — jamás un 0.
  4. **Cada bloque degrada solo y lo declara.** Sin FMP no hay estados contables; sin Gemini el
     análisis conserva TODOS sus números y lo único que falta es la prosa, con su propio motivo
     aparte del general.
"""

from __future__ import annotations

from datetime import date, datetime
from enum import Enum

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.intelligence import DataAvailability

# --- Topes y pisos del dominio -------------------------------------------------------------------

# Piso del denominador para calcular un margen o un ratio. Por debajo de un millón de dólares de
# ingresos, un cociente se dispara y cambia de signo sin que la empresa haya hecho nada distinto.
MIN_ABS_DENOMINATOR = 1_000_000.0

# Piso del EPS base para poder derivar un precio implícito. Con un EPS de medio centavo, el múltiplo
# implícito es enorme y multiplicar por él convierte cualquier variación en un número absurdo.
MIN_ABS_EPS_FOR_MULTIPLE = 0.01

# Cuántos períodos contables se piden y se conservan. Cinco años (o cinco trimestres) alcanzan para
# ver una tendencia; más filas engordan el prompt sin cambiar el diagnóstico.
MAX_STATEMENT_PERIODS = 5

# Tope del historial de conversación que se acepta y se reinyecta. El chat contable es stateless (el
# cliente es dueño del hilo), y sin tope un cliente podría empujar un prompt de megabytes.
MAX_HISTORY_TURNS = 20
MAX_TURN_CHARS = 4000


# --- Vocabulario ---------------------------------------------------------------------------------


class StatementPeriod(str, Enum):
    """Periodicidad de los estados contables pedidos.

    Viaja en el request Y en la respuesta porque un margen trimestral y uno anual no se comparan
    entre sí: una respuesta sin decir qué período mira invita exactamente a esa comparación.
    """

    ANNUAL = "ANNUAL"
    QUARTER = "QUARTER"


class FlagKind(str, Enum):
    """Si la señal es un riesgo (`RED`) o una fortaleza (`GREEN`)."""

    RED = "RED"
    GREEN = "GREEN"


class FlagSeverity(str, Enum):
    """Cuánto pesa la señal. `INFO` existe para las observaciones que valen decirse sin ser una
    advertencia: sin ese nivel, todo lo que no es grave tendría que inflarse o descartarse.
    """

    INFO = "INFO"
    WARNING = "WARNING"
    CRITICAL = "CRITICAL"


class CriteriaSource(str, Enum):
    """De dónde sale una bandera.

    Hoy solo existe `RULE`: umbrales explícitos evaluados en código, reproducibles. El enum existe
    desde el día uno para que, cuando aparezca una bandera sugerida por un modelo, los clientes
    viejos puedan distinguirla en vez de mostrar las dos con el mismo peso.
    """

    RULE = "RULE"


class NarrativeSource(str, Enum):
    """Quién escribió la prosa de la respuesta.

    `LLM` marca el texto redactado por el modelo sobre números ya calculados. `NONE` es lo que viaja
    cuando no hay narrativa (sin credenciales, o el modelo falló): el cliente tiene que poder
    distinguir "el modelo no dijo nada" de "el modelo dijo que no hay nada que decir".
    """

    LLM = "LLM"
    NONE = "NONE"


class ValuationBasis(str, Enum):
    """Cómo se derivó el precio implícito de un escenario.

    `PE_MULTIPLE_HELD` es el único método que este simulador usa: se mantiene el múltiplo
    precio/ganancias actual y se mueve el EPS. Es una convención, no una valuación — y por eso viaja
    en la respuesta en vez de quedar escondida en el código.

    `NOT_APPLICABLE` cuando el EPS base no da para sostener un múltiplo (cero, negativo o demasiado
    cerca de cero).
    """

    PE_MULTIPLE_HELD = "PE_MULTIPLE_HELD"
    NOT_APPLICABLE = "NOT_APPLICABLE"


class ScenarioCase(str, Enum):
    """Las tres columnas de la matriz de sensibilidad."""

    BEAR = "BEAR"
    BASE = "BASE"
    BULL = "BULL"


class ConversationRole(str, Enum):
    USER = "USER"
    ASSISTANT = "ASSISTANT"


# --- Estados contables ---------------------------------------------------------------------------


class IncomeStatementBlock(BaseModel):
    """Estado de resultados de un período, con sus márgenes ya calculados.

    Los márgenes se derivan acá y no se le piden al proveedor: cada endpoint los publica con nombres
    distintos y a veces en fracción y a veces en porcentaje, y una división en código es más barata
    que reconciliar tres vocabularios. `None` cuando la base de ingresos es demasiado chica para que
    el cociente signifique algo.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    period_end: date | None = None
    period_label: str | None = None

    revenue: float | None = None
    cost_of_revenue: float | None = None
    gross_profit: float | None = None
    operating_expenses: float | None = None
    operating_income: float | None = None

    # EBITDA: si el proveedor no lo publica, se reconstruye como resultado operativo + D&A. Cuál de
    # las dos cosas pasó se declara en `ebitda_is_derived`, porque un EBITDA reconstruido puede no
    # coincidir con el que la empresa reporta en su presentación.
    ebitda: float | None = None
    ebitda_is_derived: bool = False

    depreciation_amortization: float | None = None
    interest_expense: float | None = None
    income_before_tax: float | None = None
    income_tax_expense: float | None = None
    net_income: float | None = None
    eps_diluted: float | None = None
    weighted_shares_diluted: float | None = None

    gross_margin_pct: float | None = None
    operating_margin_pct: float | None = None
    ebitda_margin_pct: float | None = None
    net_margin_pct: float | None = None
    effective_tax_rate_pct: float | None = None


class BalanceSheetBlock(BaseModel):
    """Balance general de un período, con los ratios de estructura ya calculados."""

    model_config = ConfigDict(strict=True, extra="forbid")

    period_end: date | None = None
    period_label: str | None = None

    total_assets: float | None = None
    current_assets: float | None = None
    cash_and_equivalents: float | None = None
    inventory: float | None = None
    total_liabilities: float | None = None
    current_liabilities: float | None = None
    total_debt: float | None = None
    total_equity: float | None = None

    current_ratio: float | None = None
    debt_to_equity: float | None = None

    # Deuda neta: deuda total − caja. Puede ser NEGATIVA y eso es un dato, no un error: significa que
    # la empresa tiene más caja que deuda.
    net_debt: float | None = None

    equity_ratio_pct: float | None = None


class CashFlowBlock(BaseModel):
    """Flujo de caja de un período.

    `fcf_conversion_pct` (FCF sobre resultado neto) es la línea que más dice de las tres: una empresa
    que gana en el papel y no genera caja tiene un problema que el estado de resultados no muestra.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    period_end: date | None = None
    period_label: str | None = None

    operating_cash_flow: float | None = None
    capital_expenditure: float | None = None
    free_cash_flow: float | None = None
    free_cash_flow_is_derived: bool = False
    dividends_paid: float | None = None
    share_repurchases: float | None = None
    net_change_in_cash: float | None = None

    fcf_conversion_pct: float | None = None
    capex_to_revenue_pct: float | None = None


class DupontBlock(BaseModel):
    """Descomposición DuPont del ROE: margen neto × rotación de activos × apalancamiento.

    Existe como bloque propio porque responde una pregunta que el ROE solo no responde: **de dónde
    viene** la rentabilidad. Dos empresas con 20% de ROE, una por margen y otra por deuda, son dos
    inversiones distintas.

    `roe_pct` es el producto de los tres factores y es **algebraicamente idéntico** a resultado neto /
    patrimonio: los tres cocientes se cancelan. Se publica igual —en vez de dejar que el cliente lo
    multiplique— para que la pantalla y una nota guardada muestren exactamente el mismo número, con el
    mismo redondeo.

    Por eso NO hay un campo de "reconciliación" entre el producto y el ROE directo: sería un chequeo
    que no puede fallar, y un flag verde permanente da una sensación de verificación que no existe.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    net_margin_pct: float | None = None
    asset_turnover: float | None = None
    equity_multiplier: float | None = None

    roe_pct: float | None = None

    criteria_source: CriteriaSource = CriteriaSource.RULE

    @property
    def is_complete(self) -> bool:
        return (
            self.net_margin_pct is not None
            and self.asset_turnover is not None
            and self.equity_multiplier is not None
        )


class AnalysisFlag(BaseModel):
    """Una señal contable, con el umbral que la disparó a la vista.

    `detail` incluye SIEMPRE el valor medido y el umbral: "Deuda/Equity de 3,20x (umbral 3,00x)" es
    verificable y discutible; "apalancamiento alto" es una opinión sin respaldo. `criteria_source`
    declara que el criterio es una regla del producto y no el juicio de un modelo.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    code: str
    kind: FlagKind
    severity: FlagSeverity
    title: str
    detail: str

    metric_value: float | None = None
    threshold: float | None = None

    criteria_source: CriteriaSource = CriteriaSource.RULE


class ConversationTurn(BaseModel):
    """Un turno del hilo del diagnóstico contable.

    El historial lo manda el CLIENTE en cada request y el backend no lo persiste: el hilo es de la
    pantalla que lo está mostrando, y guardarlo del lado del servidor obligaría a decidir cuándo
    expira una conversación que el usuario todavía puede tener abierta.
    """

    # strict=False (default) deliberado, igual que el resto de los schemas de request: este modelo
    # viaja DENTRO del cuerpo del pedido y JSON no tiene tipo nativo para Enum — `role` llega como
    # string y necesita coerción.
    model_config = ConfigDict(extra="forbid")

    role: ConversationRole
    content: str = Field(min_length=1, max_length=MAX_TURN_CHARS)


class FinancialAnalysisRequest(BaseModel):
    """Pedido de diagnóstico contable, con o sin pregunta.

    Sin `question` el endpoint devuelve el diagnóstico completo (los números y las banderas más una
    lectura general). Con `question`, además responde eso en particular sobre los mismos datos: es el
    modo conversacional, y por eso el historial viaja acá.
    """

    # strict=False (default) deliberado, igual que el resto de los schemas de request: valida JSON
    # externo de un request HTTP, donde el período llega como string ("ANNUAL") y no como Enum.
    model_config = ConfigDict(extra="forbid")

    ticker: str = Field(min_length=1, max_length=20)
    period: StatementPeriod = StatementPeriod.ANNUAL

    question: str | None = Field(default=None, min_length=1, max_length=MAX_TURN_CHARS)

    history: list[ConversationTurn] = Field(
        default_factory=list, max_length=MAX_HISTORY_TURNS
    )

    @property
    def normalized_ticker(self) -> str:
        return self.ticker.strip().upper()


class FinancialAnalysisResponse(BaseModel):
    """Diagnóstico contable: los números calculados, las banderas y la lectura del modelo.

    `narrative_degradation_reason` va SEPARADO de `degradation_reason` porque son dos ausencias
    distintas: sin estados contables no hay análisis, pero sin modelo el análisis está completo y lo
    único que falta es la prosa. Un solo campo obligaría a elegir cuál de las dos contar.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    ticker: str
    company_name: str | None = None
    period: StatementPeriod
    generated_at: datetime

    # Del más reciente al más viejo. Listas paralelas y no una lista de tripletas: los tres estados
    # pueden venir con distinta cantidad de períodos, y aparearlos a la fuerza obligaría a inventar
    # filas vacías para completar.
    income_statements: list[IncomeStatementBlock] = Field(default_factory=list)
    balance_sheets: list[BalanceSheetBlock] = Field(default_factory=list)
    cash_flows: list[CashFlowBlock] = Field(default_factory=list)

    dupont: DupontBlock = Field(default_factory=DupontBlock)
    flags: list[AnalysisFlag] = Field(default_factory=list)

    # La lectura del modelo sobre los números de arriba. `None` cuando no se pudo generar.
    narrative: str | None = None
    narrative_source: NarrativeSource = NarrativeSource.NONE

    # El hilo completo, con la pregunta y la respuesta de este turno ya agregadas. Se devuelve armado
    # para que el cliente no tenga que reconstruirlo y mandar un historial que no coincida con lo que
    # el backend efectivamente vio.
    history: list[ConversationTurn] = Field(default_factory=list)

    availability: DataAvailability = DataAvailability.UNAVAILABLE
    degradation_reason: str | None = None
    narrative_degradation_reason: str | None = None
    served_from_cache: bool = False

    @property
    def has_statements(self) -> bool:
        return bool(self.income_statements or self.balance_sheets or self.cash_flows)


# --- Simulador -----------------------------------------------------------------------------------


class ScenarioVariables(BaseModel):
    """Las palancas del escenario. Todas opcionales: un escenario que solo mueve la tasa de interés
    es una pregunta legítima, y exigir las cuatro obligaría a inventar valores para las otras tres.

    Los rangos son anchos pero finitos: un crecimiento de +10.000% no es un escenario, es un error de
    tipeo, y proyectarlo produciría un precio implícito que el cliente mostraría en serio.

    `custom_event` es la única entrada que el modelo lee como texto. **No entra en ninguna fórmula**:
    su efecto es cualitativo y la respuesta lo dice. Dejar que un rumor moviera los números
    significaría que el modelo elige un coeficiente, que es exactamente lo que este diseño evita.
    """

    # strict=False (default) deliberado, igual que el resto de los schemas de request: las palancas
    # llegan en el cuerpo de un POST y un porcentaje redondo viaja como entero JSON (`25`, no `25.0`),
    # que en modo estricto sería rechazado por no ser float. `allow_inf_nan=False` SÍ se mantiene:
    # coerción de tipo es una cosa y aceptar NaN/infinito en una proyección es otra.
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)

    revenue_growth_pct: float | None = Field(default=None, ge=-100, le=500)
    ebitda_margin_pct: float | None = Field(default=None, ge=-100, le=100)
    interest_rate_pct: float | None = Field(default=None, ge=0, le=100)
    inflation_pct: float | None = Field(default=None, ge=-50, le=500)

    custom_event: str | None = Field(default=None, min_length=1, max_length=2000)

    @property
    def has_quantitative_lever(self) -> bool:
        """¿Hay al menos una variable que mueva las cuentas?

        Un escenario con SOLO un rumor es válido y se responde, pero su proyección es igual a la
        base — y la respuesta tiene que poder decirlo en vez de mostrar una variación de 0% como si
        fuera el resultado del análisis.
        """

        return any(
            value is not None
            for value in (
                self.revenue_growth_pct,
                self.ebitda_margin_pct,
                self.interest_rate_pct,
                self.inflation_pct,
            )
        )


class ScenarioBaseline(BaseModel):
    """El punto de partida de la simulación, con la fecha de los datos.

    La fecha va arriba y siempre: proyectar desde un balance de hace dos años y presentarlo sin decir
    de cuándo son los números es la forma más fácil de que una simulación se lea como una previsión
    del presente.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    period_end: date | None = None
    period_label: str | None = None
    period: StatementPeriod = StatementPeriod.ANNUAL

    revenue: float | None = None
    ebitda: float | None = None
    ebitda_margin_pct: float | None = None
    depreciation_amortization: float | None = None
    interest_expense: float | None = None
    total_debt: float | None = None
    implied_interest_rate_pct: float | None = None
    effective_tax_rate_pct: float | None = None
    net_income: float | None = None
    eps: float | None = None
    shares_outstanding: float | None = None
    free_cash_flow: float | None = None

    # El EPS que produce la cascada del simulador SIN mover ninguna variable, y contra el que se
    # miden todas las variaciones.
    #
    # No coincide con `eps` —el que la empresa reportó— y esa diferencia es esperable: la cascada
    # modela EBITDA → amortizaciones → intereses → impuestos, y una empresa real tiene además
    # resultados no operativos, participaciones minoritarias y ajustes que el modelo no reproduce.
    #
    # Los dos viajan porque cumplen funciones distintas: `eps` es el dato de la empresa y
    # `model_eps` es el punto cero del simulador. Medir las variaciones contra `eps` metería el error
    # de aproximación del modelo dentro del resultado, y un escenario sin cambios mostraría una
    # variación distinta de cero — que se leería como el efecto de algo.
    model_eps: float | None = None

    # Precio de referencia y múltiplo del modelo. El múltiplo se calcula contra `model_eps` por la
    # misma razón: así un escenario sin cambios devuelve exactamente el precio de referencia.
    reference_price: float | None = None
    price_earnings_multiple: float | None = None


class ScenarioProjection(BaseModel):
    """Las métricas proyectadas de un caso, con su variación contra la base.

    Los deltas se calculan acá y no se dejan al cliente para que la nota que se guarde y la pantalla
    digan el mismo número: son la misma afirmación y no puede haber dos versiones.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    revenue: float | None = None
    ebitda: float | None = None
    ebitda_margin_pct: float | None = None
    operating_income: float | None = None
    interest_expense: float | None = None
    net_income: float | None = None
    eps: float | None = None
    free_cash_flow: float | None = None

    revenue_change_pct: float | None = None
    ebitda_change_pct: float | None = None
    eps_change_pct: float | None = None
    free_cash_flow_change_pct: float | None = None

    # Precio que resultaría de mantener el múltiplo actual con el EPS proyectado. `None` cuando no
    # hay múltiplo que sostener; **nunca 0**.
    implied_price: float | None = None
    implied_price_change_pct: float | None = None


class SensitivityCase(BaseModel):
    """Una columna de la matriz: qué variables se aplicaron y qué salió.

    Las variables aplicadas viajan con el resultado para que el caso sea reproducible: un "bear" con
    un −18% de EPS no dice nada si no se puede ver que salió de crecer 5 puntos menos y perder 2
    puntos de margen.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    case: ScenarioCase
    label: str
    variables: ScenarioVariables
    projection: ScenarioProjection


class ScenarioSimulationRequest(BaseModel):
    # strict=False (default) deliberado, igual que el resto de los schemas de request: valida JSON
    # externo de un request HTTP, donde el período llega como string ("ANNUAL") y no como Enum.
    model_config = ConfigDict(extra="forbid")

    ticker: str = Field(min_length=1, max_length=20)
    period: StatementPeriod = StatementPeriod.ANNUAL
    variables: ScenarioVariables = Field(default_factory=ScenarioVariables)

    @property
    def normalized_ticker(self) -> str:
        return self.ticker.strip().upper()


class ScenarioSimulationResult(BaseModel):
    """Resultado de una simulación "qué pasaría si".

    Tres campos que no son decorativos y que el cliente tiene que mostrar:

      - `model_assumptions`: qué se mantuvo constante y con qué coeficientes. Es lo que convierte la
        proyección en un cálculo discutible en vez de un pronóstico.
      - `valuation_basis`: cómo se derivó el precio. `PE_MULTIPLE_HELD` significa "el mercado le paga
        lo mismo por cada peso de ganancia", que es una convención y no una predicción.
      - `custom_event_is_qualitative`: si el escenario traía un rumor, avisa que NO movió ningún
        número. Sin esto, un usuario que escribe "pierden el juicio" y ve un EPS proyectado creería
        que el sistema cuantificó el juicio.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    ticker: str
    company_name: str | None = None
    generated_at: datetime

    baseline: ScenarioBaseline = Field(default_factory=ScenarioBaseline)
    applied_variables: ScenarioVariables = Field(default_factory=ScenarioVariables)

    projection: ScenarioProjection = Field(default_factory=ScenarioProjection)
    sensitivity: list[SensitivityCase] = Field(default_factory=list)

    valuation_basis: ValuationBasis = ValuationBasis.NOT_APPLICABLE
    valuation_note: str | None = None
    model_assumptions: list[str] = Field(default_factory=list)

    custom_event: str | None = None
    custom_event_is_qualitative: bool = True

    narrative: str | None = None
    narrative_source: NarrativeSource = NarrativeSource.NONE

    availability: DataAvailability = DataAvailability.UNAVAILABLE
    degradation_reason: str | None = None
    narrative_degradation_reason: str | None = None
    served_from_cache: bool = False

    @property
    def case_by_kind(self) -> dict[ScenarioCase, SensitivityCase]:
        return {case.case: case for case in self.sensitivity}
