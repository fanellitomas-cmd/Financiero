"""Schemas de `/api/v1/portfolio-builder/*` — el Constructor de Portafolios.

Simula cómo quedaría repartido un presupuesto entre varios activos, con tres formas de expresar cada
posición (unidades, monto en dólares, porcentaje del presupuesto) y la opción de reemplazar el precio
de mercado por un **precio esperado** propio.

Tres decisiones del contrato que conviene leer antes que los campos:

**Las unidades son enteras y lo que no alcanza queda en efectivo.** Un presupuesto de US$ 1.000
contra un precio de US$ 300 compra 3 unidades y deja US$ 100 sin asignar, no 3,33 unidades. La
alternativa —fracciones— haría que `cash_unallocated` fuera siempre 0 y el campo no dijera nada. Se
declara en `unit_rounding` para que quien lea la respuesta no tenga que deducirlo de las cuentas.

**El retorno a 1 año se mide siempre contra precios REALES**, incluso en las posiciones con precio
personalizado. Un retorno calculado desde un precio inventado sería un número sin referente: lo que
pasó con el activo el año pasado no cambia porque el usuario suponga otro precio de entrada. Lo que
sí depende del precio personalizado son los PESOS con los que ese retorno entra al total, y por eso
la respuesta lo dice en `notes`.

**El retorno del portafolio declara su cobertura.** Si tres de cinco posiciones no tienen histórico,
`portfolio_return_1y_pct` se calcula sobre el 40% del capital que sí se pudo medir y
`return_coverage_pct` dice exactamente eso. Sin ese campo, una cartera medida a medias se leería con
la misma autoridad que una medida entera.
"""

from __future__ import annotations

from datetime import date, datetime
from enum import Enum

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import AssetType
from app.schemas.intelligence import DataAvailability
from app.schemas.portfolio_audit import (
    PortfolioSector,
    RiskLevel,
    WeightingBasis,
)

# Tope de posiciones por simulación. Cada una puede costar una cotización y un histórico, así que el
# límite es de gasto en el proveedor, no de gusto.
MAX_PORTFOLIO_ITEMS = 30

# Presupuesto máximo. Es alto a propósito —no es una restricción de producto— pero finito: sin tope,
# un 1e308 propaga infinitos por toda la aritmética de porcentajes.
MAX_BUDGET_USD = 1_000_000_000.0

# Precio mínimo utilizable. Por debajo de un centavo, `presupuesto / precio` da cantidades de
# unidades que no representan ninguna operación real y desbordan cualquier gráfico.
MIN_USABLE_PRICE = 0.01


class AllocationType(str, Enum):
    """Cómo se expresa el tamaño de una posición.

    Las tres conviven en la misma simulación a propósito: alguien puede saber que quiere 100 acciones
    de una, US$ 5.000 de otra y el 20% del resto en una tercera, y obligarlo a traducir todo a una
    sola unidad es pedirle que haga a mano justamente la cuenta que este endpoint existe para hacer.
    """

    UNITS = "UNITS"
    AMOUNT_USD = "AMOUNT_USD"
    PERCENTAGE = "PERCENTAGE"


class UnitRounding(str, Enum):
    """Qué se hizo con la fracción de unidad que no llega a entera.

    Un solo valor hoy, y existe igual como campo del contrato: si el producto algún día soporta
    fracciones, un cliente que ya lee este campo no va a tener que adivinar cuál de las dos cosas
    está mirando (mismo criterio que `WeightingBasis` en la Auditoría).
    """

    FLOOR_TO_WHOLE_UNITS = "FLOOR_TO_WHOLE_UNITS"


class PriceSource(str, Enum):
    """De dónde salió el precio con el que se calculó la posición."""

    MARKET = "MARKET"
    CUSTOM = "CUSTOM"
    UNAVAILABLE = "UNAVAILABLE"


class PortfolioItemInput(BaseModel):
    """Una posición pedida por el usuario.

    `custom_price` es el corazón de la feature: con un precio propio, la simulación deja de depender
    del proveedor y se puede correr sobre un escenario ("¿y si entro a US$ 80?") o sin credenciales
    de mercado.
    """

    # strict=False (default) deliberado, igual que el resto de los schemas de request: valida JSON
    # externo de un request HTTP, donde el tipo de activo llega como string y un monto redondo como
    # entero.
    model_config = ConfigDict(extra="forbid")

    ticker: str = Field(min_length=1, max_length=20)
    asset_type: AssetType = AssetType.STOCK

    custom_price: float | None = Field(
        default=None,
        gt=0,
        le=MAX_BUDGET_USD,
        description=(
            "Precio esperado a usar en lugar del precio de mercado. Si viaja, la posición se calcula "
            "con este número y la respuesta lo marca con `is_custom_price`."
        ),
    )

    allocation_type: AllocationType
    allocation_value: float = Field(
        gt=0,
        description=(
            "Unidades si `allocation_type=UNITS`, dólares si `AMOUNT_USD`, porcentaje del "
            "presupuesto si `PERCENTAGE`."
        ),
    )

    @property
    def normalized_ticker(self) -> str:
        return self.ticker.strip().upper()


class PortfolioSimulationRequest(BaseModel):
    # strict=False (default) deliberado: mismo motivo que `PortfolioItemInput`.
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)

    total_budget: float = Field(gt=0, le=MAX_BUDGET_USD)
    items: list[PortfolioItemInput] = Field(
        min_length=1, max_length=MAX_PORTFOLIO_ITEMS
    )


class PortfolioAllocationItem(BaseModel):
    """Una posición ya resuelta: qué precio se usó, cuántas unidades entran y cuánto pesa.

    `market_price` y `effective_price` viajan los dos incluso cuando son iguales: con un precio
    personalizado, ver el de mercado al lado es lo que permite juzgar si el supuesto es agresivo, y
    esconderlo dejaría al usuario comparando contra nada.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ticker: str
    name: str | None = None
    sector: PortfolioSector
    sector_label: str

    market_price: float | None = None
    effective_price: float | None = None
    is_custom_price: bool = False
    price_source: PriceSource

    units: int = Field(ge=0)
    invested_amount: float = Field(ge=0)
    percentage_of_total: float = Field(ge=0, le=100)

    return_1y_pct: float | None = None
    # La fecha de la vela que se usó como punto de partida. Sin ella el retorno no es verificable:
    # "un año atrás" cae en fin de semana o feriado la mayoría de las veces, y cada proveedor
    # resuelve ese hueco distinto.
    return_1y_from_date: date | None = None

    # Por qué esta posición quedó en 0 unidades o sin retorno. Es un campo por ITEM y no global: en
    # una cartera de diez, que falle un símbolo no dice nada de los otros nueve.
    note: str | None = None


class SectorAmountAllocation(BaseModel):
    """Peso de un sector medido en DINERO invertido.

    Se llama distinto que `SectorAllocation` de la Auditoría a propósito, porque mide otra cosa: la
    Auditoría reparte la watchlist equiponderada por cantidad de activos (no guarda montos), y acá el
    peso es el capital efectivamente asignado. Dos clases con el mismo nombre y semánticas distintas
    invitarían a comparar un 40% con el otro 40% como si fueran lo mismo.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    sector: PortfolioSector
    label: str
    amount: float = Field(ge=0)
    percentage_of_total: float = Field(ge=0, le=100)
    ticker_count: int = Field(ge=0)
    tickers: list[str] = Field(default_factory=list)


class PortfolioSimulationResult(BaseModel):
    """El reparto completo del presupuesto, con su riesgo de concentración y su retorno histórico.

    `over_budget_amount` existe para no tener que mentir: si los montos pedidos suman más que el
    presupuesto, dejar `cash_unallocated` en negativo afirmaría que hay efectivo negativo, y recortar
    posiciones en silencio obligaría a elegir a cuál sacarle plata — una decisión del usuario, no del
    servidor. Se calcula lo pedido, el excedente se declara y el efectivo queda en 0.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    generated_at: datetime

    total_budget: float = Field(ge=0)
    allocated_amount: float = Field(ge=0)
    cash_unallocated: float = Field(ge=0)
    cash_pct: float = Field(ge=0, le=100)
    over_budget_amount: float | None = Field(default=None, ge=0)

    items: list[PortfolioAllocationItem] = Field(default_factory=list)
    sector_allocation: list[SectorAmountAllocation] = Field(default_factory=list)
    weighting_basis: WeightingBasis = WeightingBasis.MARKET_VALUE

    portfolio_return_1y_pct: float | None = None
    # Qué porcentaje del capital asignado tiene retorno medible. 100 = la cartera entera; 0 = no se
    # pudo medir nada y `portfolio_return_1y_pct` viaja en `null`.
    return_coverage_pct: float = Field(default=0.0, ge=0, le=100)

    # El nivel usa la MISMA escala que la Auditoría (`RiskLevel`) sobre los mismos umbrales: la misma
    # concentración no puede dar dos veredictos distintos según la pantalla que la mire.
    risk_score: RiskLevel | None = None
    herfindahl_index: float | None = Field(default=None, ge=0, le=1)
    top_sector: PortfolioSector | None = None
    top_sector_weight_pct: float | None = Field(default=None, ge=0, le=100)
    risk_notes: list[str] = Field(default_factory=list)

    unit_rounding: UnitRounding = UnitRounding.FLOOR_TO_WHOLE_UNITS

    availability: DataAvailability
    degradation_reason: str | None = None
    # Supuestos y aclaraciones del cálculo, en el mismo espíritu que `model_assumptions` del
    # simulador de escenarios: una cuenta sin sus supuestos tiene la autoridad de un resultado y la
    # solidez de una estimación al margen.
    notes: list[str] = Field(default_factory=list)
