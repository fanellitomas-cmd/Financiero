"""Schemas de `/api/v1/corporate/*` — el Corporate Intelligence Hub.

Cuatro vistas sobre la vida corporativa de un activo, cada una con su fuente y su degradación
propia: el calendario de balances y el histórico de sorpresas (FMP), los reportes ante la SEC (FMP,
con síntesis opcional de Gemini) y el feed de noticias y rumores (Tavily).

Tres decisiones de contrato que atraviesan el módulo:

  1. **La sorpresa se calcula en código y puede no existir.** El porcentaje `(reportado −
     estimado) / |estimado|` es basura cuando el estimado ronda cero: una empresa que estimaba
     −0,01 y reportó +0,05 daría un "600% de sorpresa" que no significa nada. Debajo de un piso, el
     porcentaje viaja en `null` y solo se informa la diferencia absoluta. Rellenarlo con un número
     enorme sería inventar una magnitud.
  2. **La categoría y el sentimiento de una noticia declaran de dónde salen.** Se derivan de
     palabras clave del título, en código y de forma determinística, y cada ítem lo dice en
     `classification_source`. Un titular etiquetado BEARISH por un heurístico NO es el veredicto de
     un analista, y presentarlo sin esa distinción convertiría una pista en una afirmación.
  3. **Cada bloque degrada solo y lo declara.** Sin credenciales, sin datos del proveedor o sin
     Gemini, la respuesta mantiene su forma con la lista vacía, `availability` y un motivo legible —
     nunca un 503 que obligue al cliente a adivinar si el activo no tiene balances o si el backend
     no está configurado.
"""

from __future__ import annotations

from datetime import date, datetime
from enum import Enum

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.intelligence import DataAvailability

# Piso del estimado para calcular un porcentaje de sorpresa. De 1 centavo de EPS para abajo el
# cociente se dispara y cambia de signo sin que la empresa haya hecho nada distinto. El piso es
# inclusivo: el estimado tiene que SUPERARLO para que el porcentaje se calcule.
MIN_ABS_ESTIMATE_FOR_PCT = 0.01

# Ídem para ingresos, en dólares: de un millón para abajo, un desvío de miles da porcentajes de tres
# cifras sobre una base que es ruido contable.
MIN_ABS_REVENUE_FOR_PCT = 1_000_000.0


class EarningsSession(str, Enum):
    """Cuándo reporta la empresa respecto de la rueda.

    `UNKNOWN` es un valor de primera clase y frecuente: muchos proveedores no traen el horario para
    fechas lejanas. Suponer BMO cuando no se sabe haría que alguien planifique una operación para la
    apertura sobre un dato inventado.
    """

    BMO = "BMO"
    AMC = "AMC"
    DURING = "DURING"
    UNKNOWN = "UNKNOWN"


class EarningsStatus(str, Enum):
    """Si el balance ya se publicó.

    Se deriva de la presencia de valores reportados, no de la fecha: un balance de ayer sin números
    cargados sigue siendo `SCHEDULED` para el usuario, porque no hay nada que leer.
    """

    SCHEDULED = "SCHEDULED"
    REPORTED = "REPORTED"


class SurpriseDirection(str, Enum):
    BEAT = "BEAT"
    MISS = "MISS"
    IN_LINE = "IN_LINE"
    UNKNOWN = "UNKNOWN"


class EarningsEvent(BaseModel):
    """Un balance: el programado (solo estimaciones) o el ya publicado (con reportado y sorpresa)."""

    model_config = ConfigDict(strict=True, extra="forbid")

    ticker: str
    company_name: str | None = None
    event_date: date
    session: EarningsSession = EarningsSession.UNKNOWN
    status: EarningsStatus = EarningsStatus.SCHEDULED

    # Período fiscal tal como lo nombra el proveedor ("Q3 2026"). Texto y no un par
    # (año, trimestre): las empresas con ejercicio desfasado numeran distinto, y normalizarlo
    # inventaría un calendario que no es el suyo.
    fiscal_period: str | None = None

    # Cierre del trimestre que se reporta, cuando el proveedor lo manda. Va aparte de
    # `fiscal_period` y no derivado de él: FMP manda la fecha de cierre pero no la etiqueta, y
    # convertir un 30/06 en "Q2" sería inventarle el calendario fiscal a la empresa — el trimestre
    # que cierra en junio es el Q3 de varias, no el Q2.
    fiscal_period_end: date | None = None

    eps_estimated: float | None = None
    eps_actual: float | None = None

    # Diferencia absoluta reportado − estimado. Existe siempre que existan los dos, incluso cuando
    # el porcentaje no se puede calcular.
    eps_surprise: float | None = None

    # `None` cuando el estimado está demasiado cerca de cero para que un cociente signifique algo.
    eps_surprise_pct: float | None = None

    revenue_estimated: float | None = None
    revenue_actual: float | None = None
    revenue_surprise: float | None = None
    revenue_surprise_pct: float | None = None

    surprise_direction: SurpriseDirection = SurpriseDirection.UNKNOWN

    @property
    def has_actuals(self) -> bool:
        return self.eps_actual is not None or self.revenue_actual is not None


class EarningsCalendar(BaseModel):
    """Balances en un rango de fechas."""

    model_config = ConfigDict(strict=True, extra="forbid")

    from_date: date
    to_date: date
    events: list[EarningsEvent] = Field(default_factory=list)
    availability: DataAvailability = DataAvailability.UNAVAILABLE
    degradation_reason: str | None = None
    served_from_cache: bool = False

    # Cuántos eventos quedaron afuera del filtro por sector por no estar en el catálogo local.
    #
    # Se informa en vez de descartarlos en silencio: sin el sector no se puede afirmar que un
    # símbolo pertenezca al que se pidió, y una lista más corta sin explicación se lee como "esta
    # semana no reporta nadie más de tecnología".
    unclassified_by_sector: int = Field(default=0, ge=0)

    @property
    def total(self) -> int:
        return len(self.events)


class EarningsHistory(BaseModel):
    """Histórico de sorpresas de un ticker, con la estadística agregada calculada en código."""

    model_config = ConfigDict(strict=True, extra="forbid")

    ticker: str
    quarters: list[EarningsEvent] = Field(default_factory=list)

    # Cuántos de los trimestres MEDIDOS superaron la estimación. El denominador es
    # `measured_quarters`, no `len(quarters)`: un trimestre sin estimación no se puede contar ni
    # como acierto ni como fallo, y meterlo en el denominador diluiría la tasa hacia abajo.
    beat_count: int = Field(default=0, ge=0)
    miss_count: int = Field(default=0, ge=0)
    in_line_count: int = Field(default=0, ge=0)
    measured_quarters: int = Field(default=0, ge=0)

    # Promedio de los porcentajes de sorpresa que SÍ se pudieron calcular. `None` cuando ninguno
    # llegó al piso: un promedio sobre cero muestras es 0, y 0 significa "reportó exactamente lo
    # esperado", que es una afirmación distinta.
    average_surprise_pct: float | None = None

    availability: DataAvailability = DataAvailability.UNAVAILABLE
    degradation_reason: str | None = None
    served_from_cache: bool = False

    @property
    def beat_rate(self) -> float | None:
        if self.measured_quarters == 0:
            return None
        return self.beat_count / self.measured_quarters


class FilingType(str, Enum):
    """Tipos de reporte que el Hub distingue.

    `OTHER` recoge todo lo demás (S-1, DEF 14A…) en vez de esconderlo: el usuario que abre la
    biblioteca de una empresa quiere ver que hay algo más, aunque el producto todavía no lo trate
    especial.
    """

    TEN_K = "10-K"
    TEN_Q = "10-Q"
    EIGHT_K = "8-K"
    OTHER = "OTHER"


class SecFiling(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    ticker: str
    filing_type: FilingType
    filed_at: datetime | None = None

    # Tal como lo nombra la SEC ("10-K/A", "8-K"), además del tipo normalizado: la enmienda de un
    # 10-K no es un 10-K nuevo, y perder el sufijo al normalizar borraría esa diferencia.
    raw_type: str | None = None

    url: str | None = None
    final_document_url: str | None = None

    # Síntesis ejecutiva generada por Gemini, solo si se pidió y se pudo. `None` no significa "el
    # reporte no dice nada": significa que no se sintetizó, y `summary_available` lo distingue.
    summary: str | None = None
    summary_available: bool = False


class FilingsResponse(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    ticker: str
    filings: list[SecFiling] = Field(default_factory=list)
    availability: DataAvailability = DataAvailability.UNAVAILABLE
    degradation_reason: str | None = None

    # Motivo separado del anterior: la lista de reportes puede haber llegado perfecta y la síntesis
    # haber fallado. Un solo campo obligaría a elegir cuál de las dos cosas contar.
    summary_degradation_reason: str | None = None

    served_from_cache: bool = False


class NewsCategory(str, Enum):
    """Qué clase de novedad es.

    `RUMOR` está primero en la clasificación por una razón de producto: una versión sin confirmar es
    lo que más se parece a información accionable y lo que más conviene marcar como tal. Etiquetarla
    CORPORATE la mezclaría con los hechos confirmados.
    """

    RUMOR = "RUMOR"
    CORPORATE = "CORPORATE"
    REGULATORY = "REGULATORY"
    EARNINGS = "EARNINGS"
    MARKET = "MARKET"


class NewsSentiment(str, Enum):
    BULLISH = "BULLISH"
    BEARISH = "BEARISH"
    NEUTRAL = "NEUTRAL"


class ClassificationSource(str, Enum):
    """De dónde salen la categoría y el sentimiento de un ítem.

    Viaja en cada noticia para que la UI pueda presentarlas como una pista y no como un análisis.
    Hoy solo existe `KEYWORD`, y el enum existe igual desde el día uno: cuando se agregue una
    clasificación por modelo, los clientes viejos van a poder distinguirla en vez de mostrar las dos
    con el mismo peso.
    """

    KEYWORD = "KEYWORD"


class CorporateNewsItem(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    # Identificador estable derivado de la URL (o del título si no hay URL). No es un id del
    # proveedor: Tavily no lo da, y el cliente necesita una clave para marcar lo ya leído.
    ref_id: str

    title: str

    # Dominio de la publicación ("reuters.com"). Se muestra siempre: una noticia sin fuente visible
    # no se puede pesar, y en un feed que mezcla rumores eso es justamente lo que hace falta.
    source: str | None = None

    published_at: datetime | None = None
    summary: str | None = None
    url: str | None = None

    category: NewsCategory = NewsCategory.MARKET
    sentiment: NewsSentiment = NewsSentiment.NEUTRAL
    classification_source: ClassificationSource = ClassificationSource.KEYWORD

    # Símbolos mencionados. Es el ticker por el que se buscó — no se infieren otros del texto, que
    # sería adivinar de qué empresa habla una nota que nombra a tres.
    tickers: list[str] = Field(default_factory=list)


class CorporateNewsFeed(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    items: list[CorporateNewsItem] = Field(default_factory=list)
    availability: DataAvailability = DataAvailability.UNAVAILABLE
    degradation_reason: str | None = None
    served_from_cache: bool = False

    # Los filtros que se aplicaron, devueltos tal cual se interpretaron. Con tres filtros
    # combinables, una lista corta es ambigua: sin esto, el cliente no puede distinguir "no hay
    # noticias" de "el filtro dejó una sola".
    applied_ticker: str | None = None
    applied_category: NewsCategory | None = None
    applied_sentiment: NewsSentiment | None = None

    # Cuántos ítems trajo el proveedor antes de filtrar. Es lo que deja decir "3 de 20" en vez de
    # solo "3".
    total_before_filters: int = Field(default=0, ge=0)

    @property
    def total(self) -> int:
        return len(self.items)
