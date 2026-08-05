"""Schemas de `POST /api/v1/tickers/search-nl` — búsqueda conversacional en lenguaje natural.

El reparto de trabajo es el mismo que en el resto del sistema y es la decisión central de este
contrato: **el modelo interpreta la intención, el código hace la búsqueda**.

  - Gemini traduce "tecnológicas baratas y sin mucha deuda" a `SearchCriteria` (sectores, rango de
    P/E, tope de Deuda/Equity…). Eso es entender lenguaje, que es lo que un LLM hace bien.
  - El filtrado corre en SQL sobre el catálogo y en código sobre los ratios reales del proveedor.
    Pedirle al modelo que "elija los tickers" sería pedirle que recuerde de memoria el P/E de cada
    empresa — el camino directo a una lista de símbolos plausibles y equivocados.

Por eso `criteria` viaja en la respuesta: el usuario (y quien depure esto) tiene que poder ver qué
entendió el modelo, aparte de qué devolvió la búsqueda. Una búsqueda que no encuentra nada porque
el modelo entendió otra cosa es indistinguible de una que no encuentra nada porque no hay
coincidencias, salvo que se muestren los criterios.
"""

from __future__ import annotations

from enum import Enum

from pydantic import BaseModel, ConfigDict, Field

from app.models.enums import ExchangeType
from app.schemas.portfolio_audit import PortfolioSector


class CriteriaSource(str, Enum):
    """De dónde salieron los criterios de búsqueda.

    `TEXT_FALLBACK` no es un error: es una búsqueda por texto sobre símbolo y nombre, que es lo que
    se puede hacer honestamente sin el modelo. Se declara para que el cliente pueda avisar que la
    consulta no se interpretó, en vez de mostrar resultados pobres como si fueran la respuesta a lo
    que el usuario preguntó.
    """

    AI = "AI"
    TEXT_FALLBACK = "TEXT_FALLBACK"


class NumericRange(BaseModel):
    """Rango pedido para un ratio. Los dos extremos son opcionales: "P/E menor a 20" es un rango
    con solo `maximum`, y forzar un mínimo inventado (0) descartaría empresas con pérdidas cuyo P/E
    es negativo — que es justamente lo que alguien buscando "baratas" podría querer ver.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    minimum: float | None = None
    maximum: float | None = None

    @property
    def is_empty(self) -> bool:
        return self.minimum is None and self.maximum is None

    def contains(self, value: float) -> bool:
        if self.minimum is not None and value < self.minimum:
            return False
        return not (self.maximum is not None and value > self.maximum)

    def describe(self, label: str, unit: str = "") -> str:
        if self.minimum is not None and self.maximum is not None:
            return f"{label} entre {self.minimum:g}{unit} y {self.maximum:g}{unit}"
        if self.maximum is not None:
            return f"{label} menor a {self.maximum:g}{unit}"
        if self.minimum is not None:
            return f"{label} mayor a {self.minimum:g}{unit}"
        return label


class SearchCriteria(BaseModel):
    """Lo que el modelo entendió de la consulta, ya normalizado al vocabulario del producto.

    Todo es opcional: una consulta puede pedir solo un sector, solo un rango de P/E, o nada
    reconocible (y ahí queda `is_empty`, que el servicio trata como "no se pudo estructurar" en vez
    de como "traeme todo").
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    sectors: list[PortfolioSector] = Field(default_factory=list)
    exchanges: list[ExchangeType] = Field(default_factory=list)

    price_earnings: NumericRange = NumericRange()
    debt_to_equity: NumericRange = NumericRange()
    return_on_equity_pct: NumericRange = NumericRange()
    revenue_growth_yoy_pct: NumericRange = NumericRange()
    market_cap_usd: NumericRange = NumericRange()

    # "que genere caja" / "con flujo de caja positivo". `None` es "no lo pidió", distinto de
    # `False` ("que NO genere caja"), que también es una búsqueda válida.
    free_cash_flow_positive: bool | None = None

    # Texto suelto que el modelo no supo estructurar pero que igual sirve para buscar por símbolo o
    # nombre ("Apple", "NVDA"). Es lo que hace que "acciones parecidas a Apple" devuelva algo.
    text_query: str | None = None

    @property
    def numeric_fields(self) -> list[tuple[str, NumericRange]]:
        """Los criterios que necesitan los ratios del proveedor, con su etiqueta legible. Se usa
        tanto para saber si hay que pedir métricas como para declarar cuáles no se pudieron
        aplicar.
        """

        return [
            ("P/E", self.price_earnings),
            ("Deuda/Equity", self.debt_to_equity),
            ("ROE", self.return_on_equity_pct),
            ("Crecimiento de ingresos", self.revenue_growth_yoy_pct),
            ("Capitalización", self.market_cap_usd),
        ]

    @property
    def requires_metrics(self) -> bool:
        return (
            any(not value.is_empty for _, value in self.numeric_fields)
            or self.free_cash_flow_positive is not None
        )

    @property
    def is_empty(self) -> bool:
        return (
            not self.sectors
            and not self.exchanges
            and not self.requires_metrics
            and not self.text_query
        )


class TickerMatch(BaseModel):
    """Un resultado de la búsqueda, con por qué entró."""

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    symbol: str
    name: str
    exchange: ExchangeType
    sector: PortfolioSector
    sector_label: str

    # `match_reason` se compone en código a partir de los valores REALES que se midieron contra los
    # criterios ("P/E de 24,30x, dentro del rango pedido (menor a 30)"), no se le pide al modelo.
    #
    # Es deliberado y es la regla anti-alucinación de este endpoint: una razón escrita por el LLM
    # sería una afirmación sobre números que el backend ya tiene medidos, con la posibilidad de que
    # no coincidan. La interpretación en prosa de la consulta —lo que sí es trabajo de lenguaje—
    # viaja aparte, en `NaturalSearchResponse.interpretation`.
    match_reason: str

    # Los ratios que se usaron para decidir, para que el cliente pueda mostrarlos sin otra consulta.
    price_earnings: float | None = None
    debt_to_equity: float | None = None
    return_on_equity_pct: float | None = None
    revenue_growth_yoy_pct: float | None = None
    market_cap_usd: float | None = None


class NaturalSearchResponse(BaseModel):
    """Respuesta de `POST /api/v1/tickers/search-nl`.

    Siempre 200 con estructura válida (salvo 401/422): sin credenciales de IA cae a búsqueda por
    texto, sin proveedor de fundamentales se aplican los criterios que no necesitan ratios, y una
    búsqueda sin coincidencias es una lista vacía con sus criterios a la vista — no un 404.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    query: str

    # Reformulación en prosa de lo que el modelo entendió ("buscás tecnológicas con múltiplo bajo y
    # poca deuda"). Esto SÍ lo escribe el LLM: es lenguaje sobre lenguaje, no una afirmación sobre
    # datos de mercado.
    interpretation: str | None = None
    criteria: SearchCriteria
    criteria_source: CriteriaSource

    results: list[TickerMatch] = Field(default_factory=list)

    # Cuántos símbolos del catálogo pasaron los filtros locales antes de mirar los ratios. Deja ver
    # que "3 resultados" salieron de haber evaluado 40 candidatos, no de que el catálogo tenga 3.
    candidates_evaluated: int = 0

    ai_available: bool = False
    metrics_available: bool = False

    # Criterios que el modelo entendió pero que no se pudieron aplicar (típicamente los numéricos,
    # cuando falta el proveedor de fundamentales). Van explícitos porque su ausencia cambia el
    # significado del resultado: sin ellos, la lista NO cumple lo que el usuario pidió.
    unapplied_criteria: list[str] = Field(default_factory=list)

    degradation_reason: str | None = None


class NaturalSearchRequest(BaseModel):
    # strict=False (default) deliberado, igual que el resto de los schemas de request: valida JSON
    # externo de un request HTTP.
    model_config = ConfigDict(extra="forbid")

    query: str = Field(
        min_length=2,
        max_length=500,
        description="La búsqueda en lenguaje natural, tal como la escribió el usuario.",
    )
    limit: int = Field(
        default=20,
        ge=1,
        le=50,
        description="Máximo de resultados a devolver.",
    )
