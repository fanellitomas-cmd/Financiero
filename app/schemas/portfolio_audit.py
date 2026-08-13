"""Schemas de `GET/POST /api/v1/watchlist/audit` — la Auditoría de Portafolio por IA.

Cuatro bloques que se calculan en código de forma determinística (distribución por sector,
concentración de riesgo, correlaciones y sugerencias de diversificación) más una narrativa que
redacta Gemini sobre esos cuatro. El reparto es deliberado: los números y los veredictos son
auditables y reproducibles, y el modelo solo los cuenta en prosa. Pedirle al LLM que calcule la
concentración abriría la puerta a que dos corridas con la misma cartera den veredictos distintos.

**Advertencia central del contrato**: la Watchlist no guarda cantidades ni precio de compra —
es una lista de seguimiento, no un portafolio con posiciones. Entonces la distribución es
EQUIPONDERADA POR CANTIDAD DE ACTIVOS, y eso viaja explícito en `weighting_basis`. Decir "70% en
Tecnología" sin aclararlo daría a entender que son 70 centavos de cada peso invertido, que es una
afirmación que este sistema no tiene datos para hacer.
"""

from __future__ import annotations

from datetime import datetime
from enum import Enum

from pydantic import BaseModel, ConfigDict, Field

# Se reutiliza el enum de la Ficha de Inteligencia Profunda en vez de declarar uno idéntico: es el
# mismo concepto (un bloque llegó completo, parcial o no llegó) y tener dos enums con los mismos
# tres valores obligaría al cliente a mapear entre ellos sin ninguna ganancia.
from app.schemas.intelligence import DataAvailability


class PortfolioSector(str, Enum):
    """Sector en el vocabulario del producto, normalizado desde el del proveedor de fundamentales
    (`Technology` -> `TECNOLOGIA`, ver `_SECTOR_TRANSLATIONS` en el servicio).

    Vocabulario cerrado y no el string crudo de FMP: la UI colorea y agrupa por sector, y un valor
    libre del proveedor (o su renombre) rompería el agrupado en silencio.

    `CRIPTO` no existe en la taxonomía GICS que usan los proveedores de acciones — se asigna en
    código por `asset_type`, sin preguntarle a nadie: una cripto no tiene sector empresario, y
    tratarla como `SIN_CLASIFICAR` esconde que es una clase de activo distinta, que es justo el
    dato que más importa en una auditoría de concentración.
    """

    TECNOLOGIA = "TECNOLOGIA"
    SALUD = "SALUD"
    SERVICIOS_FINANCIEROS = "SERVICIOS_FINANCIEROS"
    CONSUMO_DISCRECIONAL = "CONSUMO_DISCRECIONAL"
    CONSUMO_BASICO = "CONSUMO_BASICO"
    INDUSTRIA = "INDUSTRIA"
    ENERGIA = "ENERGIA"
    MATERIALES = "MATERIALES"
    SERVICIOS_PUBLICOS = "SERVICIOS_PUBLICOS"
    BIENES_RAICES = "BIENES_RAICES"
    COMUNICACIONES = "COMUNICACIONES"
    CRIPTO = "CRIPTO"
    SIN_CLASIFICAR = "SIN_CLASIFICAR"


# Etiqueta legible de cada sector. Viaja en la respuesta (`SectorAllocation.label`) para que el
# cliente no tenga que mantener su propia tabla de traducciones del enum — si se agrega un sector,
# la app vieja igual muestra su nombre en castellano en vez de un código en mayúsculas.
_SECTOR_LABELS: dict[PortfolioSector, str] = {
    PortfolioSector.TECNOLOGIA: "Tecnología",
    PortfolioSector.SALUD: "Salud",
    PortfolioSector.SERVICIOS_FINANCIEROS: "Servicios financieros",
    PortfolioSector.CONSUMO_DISCRECIONAL: "Consumo discrecional",
    PortfolioSector.CONSUMO_BASICO: "Consumo básico",
    PortfolioSector.INDUSTRIA: "Industria",
    PortfolioSector.ENERGIA: "Energía",
    PortfolioSector.MATERIALES: "Materiales",
    PortfolioSector.SERVICIOS_PUBLICOS: "Servicios públicos",
    PortfolioSector.BIENES_RAICES: "Bienes raíces",
    PortfolioSector.COMUNICACIONES: "Comunicaciones",
    PortfolioSector.CRIPTO: "Cripto",
    PortfolioSector.SIN_CLASIFICAR: "Sin clasificar",
}


def sector_label(sector: PortfolioSector) -> str:
    """Etiqueta legible de un sector. Nunca falla: un sector nuevo sin traducción cae en su propio
    código en vez de tirar un `KeyError` en el medio de una auditoría.
    """

    return _SECTOR_LABELS.get(sector, sector.value)


class WeightingBasis(str, Enum):
    """Sobre qué se calcularon los porcentajes.

    La Auditoría usa `EQUAL_WEIGHT_BY_COUNT` porque la watchlist no guarda cantidades: reparte por
    cantidad de activos. El Constructor de Portafolios sí conoce el capital de cada posición y usa
    `MARKET_VALUE`.

    Que el campo exista en las dos respuestas es lo que evita el error de leer un 40% contra el otro:
    "40% del capital" y "40% de los símbolos que sigo" son afirmaciones distintas sobre la misma
    cartera, y sin este campo un cliente tendría que deducir cuál está mirando.
    """

    EQUAL_WEIGHT_BY_COUNT = "EQUAL_WEIGHT_BY_COUNT"
    MARKET_VALUE = "MARKET_VALUE"


class RiskLevel(str, Enum):
    BAJA = "BAJA"
    MODERADA = "MODERADA"
    ALTA = "ALTA"
    CRITICA = "CRITICA"


class SectorAllocation(BaseModel):
    """Peso de un sector en la cartera, con los tickers que lo componen.

    Los tickers viajan además del porcentaje porque un "40% en Tecnología" sin decir cuáles son no
    es accionable: el usuario necesita saber qué activos concretos forman esa concentración.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    sector: PortfolioSector
    label: str
    weight_pct: float = Field(ge=0, le=100)
    ticker_count: int = Field(ge=0)
    tickers: list[str] = Field(default_factory=list)


class ConcentrationRisk(BaseModel):
    """Veredicto de concentración: nivel, titular legible y las señales que lo sostienen.

    `headline` viene armado del backend (ej. "70% concentrado en Tecnología — riesgo alto") en vez
    de dejar que el cliente lo componga: es la frase que el usuario va a leer primero, y tenerla
    acá la mantiene consistente entre la app, el push y la narrativa de la IA.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    level: RiskLevel
    headline: str
    top_sector: PortfolioSector
    top_sector_label: str
    top_sector_weight_pct: float = Field(ge=0, le=100)
    distinct_sectors: int = Field(ge=0)
    # Índice de Herfindahl-Hirschman sobre los pesos por sector, normalizado a 0-1. 1 es todo en un
    # solo sector; 1/N es el reparto perfecto entre N sectores. Se expone además del nivel porque
    # es la medida que hace comparables dos carteras: "35% en Tech" dice poco si el resto está
    # repartido en 8 sectores o en 2.
    herfindahl_index: float = Field(ge=0, le=1)
    notes: list[str] = Field(default_factory=list)


class CorrelationBasis(str, Enum):
    """De dónde sale la advertencia de correlación. Es parte del contrato y no un detalle interno:
    una correlación medida sobre precios reales y una inferida de que dos activos comparten sector
    tienen fuerza probatoria muy distinta, y el usuario merece saber cuál está leyendo.
    """

    PRICE_HISTORY = "PRICE_HISTORY"
    SECTOR = "SECTOR"


class CorrelationWarning(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    tickers: list[str]
    basis: CorrelationBasis
    # `None` cuando la base es SECTOR: no se inventa un número para una advertencia que no se midió.
    coefficient: float | None = Field(default=None, ge=-1, le=1)
    observations: int | None = Field(default=None, ge=0)
    message: str


class DiversificationSuggestion(BaseModel):
    """Un sector ausente o subrepresentado que ayudaría a balancear la cartera.

    Se sugieren SECTORES y nunca tickers concretos, aunque el pedido admitía las dos cosas: "comprá
    X" es una recomendación de inversión personalizada, y este producto declara explícitamente que
    no las da (ver el disclaimer de la Ficha). Un sector es una observación sobre la forma de la
    cartera; un símbolo sería un consejo sobre qué hacer con el dinero.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    sector: PortfolioSector
    label: str
    rationale: str


class PortfolioAudit(BaseModel):
    """Respuesta de `GET/POST /api/v1/watchlist/audit`.

    Siempre 200 con estructura válida (salvo 401): una watchlist vacía, un catálogo sin sectores o
    un entorno sin credenciales de IA devuelven la auditoría con los bloques que se pudieron armar
    y `availability` + `degradation_reason` explicando el resto, en vez de un 4xx/5xx que el cliente
    tendría que traducir a una pantalla vacía.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    generated_at: datetime
    position_count: int = Field(ge=0)
    weighting_basis: WeightingBasis = WeightingBasis.EQUAL_WEIGHT_BY_COUNT

    availability: DataAvailability

    sector_allocation: list[SectorAllocation] = Field(default_factory=list)
    # `False` cuando ningún símbolo pudo clasificarse (sin FMP y sin sectores en el catálogo). La
    # distribución igual viaja, con todo en `SIN_CLASIFICAR`: es más honesto mostrar "no sabemos el
    # sector de estos 6 activos" que una torta vacía.
    sector_data_available: bool = True

    risk_concentration: ConcentrationRisk | None = None

    correlation_warnings: list[CorrelationWarning] = Field(default_factory=list)
    # `True` si al menos un PAR se pudo medir contra precios reales (no basta con haber bajado
    # histórico: hacen falta dos series con suficientes días en común). Con `False`, las
    # advertencias que haya son heurísticas por sector — y, más importante, la AUSENCIA de
    # advertencias no significa "los medimos y no correlacionan" sino "no los pudimos medir".
    correlation_measured: bool = False

    diversification_suggestions: list[DiversificationSuggestion] = Field(
        default_factory=list
    )

    ai_summary: str | None = None
    ai_summary_available: bool = False

    degradation_reason: str | None = None
    served_from_cache: bool = False
