"""Schemas de `GET /api/v1/tickers/{ticker}/intelligence` — la Ficha de Inteligencia Profunda.

Tres bloques que se obtienen de fuentes distintas y **degradan por separado**: fundamentales
(FMP), síntesis RAG de reportes oficiales y noticias (Tavily + filings, sintetizado por Gemini) y
proyecciones multi-horizonte (Gemini sobre los dos anteriores). Cada bloque lleva su propio flag
de disponibilidad y su motivo: la Ficha muestra lo que sí llegó en vez de esconderse entera, y el
cliente nunca tiene que adivinar si un bloque vacío significa "sin datos" o "falló".

Por qué schemas nuevos y no `AssetProjection`/`HorizonScenarios` de `src/validation`: ese modelo es
la salida del Nodo 3 del motor de alertas, donde los tres horizontes comparten la MISMA forma (una
tabla de probabilidades alcista/neutral/bajista). Acá cada horizonte tiene una forma propia porque
responde una pregunta distinta — el corto plazo es dirección técnica, el mediano es escenarios con
catalizadores, y el largo es una tesis fundamental con convicción. Forzar los tres en una tabla de
probabilidades perdería justamente lo que hace útil a cada horizonte.
"""

from __future__ import annotations

from datetime import datetime
from enum import Enum

from pydantic import BaseModel, ConfigDict, Field


class DataAvailability(str, Enum):
    """Estado de un bloque de la Ficha.

    `PARTIAL` es un estado real y frecuente, no un caso raro: un ticker puede tener P/E y márgenes
    pero no PEG (sin estimaciones de crecimiento), y eso es distinto tanto de "todo bien" como de
    "no hay nada".
    """

    AVAILABLE = "AVAILABLE"
    PARTIAL = "PARTIAL"
    UNAVAILABLE = "UNAVAILABLE"


class FinancialHealth(str, Enum):
    """Semáforo de salud financiera, derivado en código a partir de los ratios.

    Se calcula con umbrales explícitos (ver `_score_financial_health`) y NO se le pide al modelo:
    es una clasificación determinística sobre números que ya tenemos, y hacerla en código la vuelve
    auditable y reproducible. Pedirla al LLM abriría la puerta a que dos corridas con los mismos
    ratios devuelvan veredictos distintos.
    """

    SOLIDA = "SOLIDA"
    ADECUADA = "ADECUADA"
    AJUSTADA = "AJUSTADA"
    DEBIL = "DEBIL"
    INDETERMINADA = "INDETERMINADA"


class RatioValue(BaseModel):
    """Un ratio con su valor y su etiqueta legible.

    `value` es `None` cuando el proveedor no lo trajo. Se expone el hueco en vez de rellenarlo con
    0: un P/E de 0 y un P/E desconocido significan cosas muy distintas para quien lee la Ficha.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    label: str
    value: float | None
    unit: str | None = Field(
        default=None,
        description="'x' para múltiplos, '%' para porcentajes, 'USD' para montos.",
    )


class Fundamentals(BaseModel):
    """Ratios clave del activo más el semáforo de salud financiera."""

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    availability: DataAvailability
    as_of: datetime | None = None
    period: str | None = Field(
        default=None, description="Período de los fundamentales: TTM, FY o Q."
    )

    price_earnings: RatioValue
    price_earnings_growth: RatioValue
    debt_to_equity: RatioValue
    debt_to_ebitda: RatioValue
    free_cash_flow: RatioValue
    free_cash_flow_yield_pct: RatioValue
    gross_margin_pct: RatioValue
    operating_margin_pct: RatioValue
    return_on_equity_pct: RatioValue
    current_ratio: RatioValue
    revenue_growth_yoy_pct: RatioValue

    financial_health: FinancialHealth = FinancialHealth.INDETERMINADA
    financial_health_notes: list[str] = Field(
        default_factory=list,
        description="Qué señales concretas sostienen el veredicto de salud financiera.",
    )
    degradation_reason: str | None = None

    @property
    def ratios(self) -> list[RatioValue]:
        """Los ratios en el orden en que conviene leerlos: valuación, apalancamiento, caja,
        rentabilidad, liquidez, crecimiento.
        """

        return [
            self.price_earnings,
            self.price_earnings_growth,
            self.debt_to_equity,
            self.debt_to_ebitda,
            self.free_cash_flow,
            self.free_cash_flow_yield_pct,
            self.gross_margin_pct,
            self.operating_margin_pct,
            self.return_on_equity_pct,
            self.current_ratio,
            self.revenue_growth_yoy_pct,
        ]


class SourceReference(BaseModel):
    """Una fuente que respalda la síntesis. Sin esto, la síntesis sería una afirmación sin
    trazabilidad — exactamente lo que la regla de cero alucinación del proyecto prohíbe.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ref_id: str
    source_type: str = Field(
        description="NEWS | SEC_10K | SEC_10Q | EARNINGS_TRANSCRIPT | OFFICIAL_ANNOUNCEMENT"
    )
    title: str | None = None
    url: str | None = None
    published_at: datetime | None = None


class RagSummary(BaseModel):
    """Síntesis de reportes oficiales (10-K/10-Q, earnings calls) y noticias.

    `key_points` y `risks` están separados a propósito: un resumen que mezcla fortalezas con
    riesgos en una sola lista deja al lector armando el balance a mano, que es justo el trabajo que
    la Ficha tiene que hacer por él.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    availability: DataAvailability
    headline: str | None = None
    key_points: list[str] = Field(default_factory=list)
    risks: list[str] = Field(default_factory=list)
    sources: list[SourceReference] = Field(default_factory=list)
    degradation_reason: str | None = None


class TrendDirection(str, Enum):
    ALCISTA = "ALCISTA"
    LATERAL = "LATERAL"
    BAJISTA = "BAJISTA"


class ConfidenceLevel(str, Enum):
    BAJA = "BAJA"
    MEDIA = "MEDIA"
    ALTA = "ALTA"


class ShortTermProjection(BaseModel):
    """Corto plazo (1-14 días): dirección técnica, no tesis de inversión. Acá lo que manda es el
    flujo y el momentum, así que la forma útil es tendencia + confianza + un argumento corto.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    horizon_label: str = "Corto plazo (1-14 días)"
    trend: TrendDirection
    confidence: ConfidenceLevel
    argument: str
    evidence_refs: list[str] = Field(default_factory=list)


class ScenarioOutlook(BaseModel):
    """Un escenario del mediano plazo. `probability_pct` es opcional porque el modelo no siempre
    tiene base para cuantificar: es preferible un escenario sin número a un número inventado.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    label: str = Field(description="BASE | ALCISTA | BAJISTA")
    narrative: str
    probability_pct: float | None = Field(default=None, ge=0, le=100)


class MediumTermProjection(BaseModel):
    """Mediano plazo (1-6 meses): escenario base contra alcista y bajista, con los catalizadores
    concretos que moverían el precio de uno a otro (resultados, guidance, regulación).
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    horizon_label: str = "Mediano plazo (1-6 meses)"
    base_case: ScenarioOutlook
    bull_case: ScenarioOutlook
    bear_case: ScenarioOutlook
    catalysts: list[str] = Field(default_factory=list)
    confidence: ConfidenceLevel = ConfidenceLevel.MEDIA
    evidence_refs: list[str] = Field(default_factory=list)


class ConvictionLevel(str, Enum):
    BAJA = "BAJA"
    MODERADA = "MODERADA"
    ALTA = "ALTA"


class LongTermProjection(BaseModel):
    """Largo plazo (1-3 años): tesis fundamental y convicción. A este horizonte el precio de hoy
    es ruido, así que no hay tendencia ni escenarios — hay una tesis, lo que la sostiene y lo que
    la invalidaría.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    horizon_label: str = "Largo plazo (1-3 años)"
    thesis: str
    conviction: ConvictionLevel
    supporting_factors: list[str] = Field(default_factory=list)
    invalidation_triggers: list[str] = Field(
        default_factory=list,
        description="Qué tendría que pasar para que la tesis deje de valer.",
    )
    evidence_refs: list[str] = Field(default_factory=list)


class Projections(BaseModel):
    """Los tres horizontes. Cada uno es opcional por separado: el modelo puede tener base para el
    corto y no para el largo, y en ese caso se sirve lo que hay.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    availability: DataAvailability
    short_term: ShortTermProjection | None = None
    medium_term: MediumTermProjection | None = None
    long_term: LongTermProjection | None = None
    degradation_reason: str | None = None


class TickerIntelligence(BaseModel):
    """Respuesta de `GET /api/v1/tickers/{ticker}/intelligence`.

    Siempre 200 con una estructura válida (salvo 401/404 de ticker inexistente): los tres bloques
    llevan su `availability` y su motivo, así que un entorno sin credenciales devuelve una Ficha
    completa en forma y explícitamente vacía en contenido, en vez de un 503 que el cliente tendría
    que traducir a mano.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ticker: str
    company_name: str | None = None
    generated_at: datetime

    fundamentals: Fundamentals
    rag_summary: RagSummary
    projections: Projections

    served_from_cache: bool = False

    @property
    def is_fully_available(self) -> bool:
        """`True` solo si los tres bloques están completos. Lo usa el cliente para decidir si
        mostrar un aviso general de "Ficha parcial".
        """

        return all(
            block == DataAvailability.AVAILABLE
            for block in (
                self.fundamentals.availability,
                self.rag_summary.availability,
                self.projections.availability,
            )
        )
