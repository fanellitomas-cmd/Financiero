"""Servicio del Corporate Intelligence Hub: balances, reportes SEC y noticias corporativas.

Un servicio para las cuatro vistas y no uno por endpoint, porque comparten lo que más cuesta hacer
bien: la caché contra proveedores externos y la degradación. Separarlos multiplicaría por cuatro un
mecanismo idéntico y dejaría que cada uno degradara distinto.

**Todo lo que es un juicio se calcula en código, de forma determinística.** El modelo interviene en
un solo lugar y solo para redactar: la síntesis de un reporte SEC. La sorpresa de un balance, la
categoría de una noticia y su sentimiento salen de reglas explícitas que se pueden leer, testear y
reproducir — y cada una declara su procedencia, para que la UI no las presente con más autoridad de
la que tienen.

Las cuatro degradaciones, todas con la misma forma (respuesta válida + `availability` + motivo):

  - **Sin FMP** → calendario, histórico y biblioteca de reportes vacíos, con el motivo.
  - **Sin Tavily** → feed de noticias vacío, con el motivo.
  - **Sin Gemini** → los reportes se listan igual; lo que falta es la síntesis, y eso se informa en
    `summary_degradation_reason` aparte del motivo general. Un solo campo obligaría a elegir entre
    contar que la lista llegó bien o que la síntesis no.
  - **El proveedor responde pero sin datos** → lista vacía SIN motivo de error y
    `availability=AVAILABLE`. Es la distinción que evita que "esta semana no reporta nadie" se lea
    como una falla.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import math
import time
from datetime import date, datetime, timedelta, timezone
from typing import Any
from urllib.parse import urlparse

from app.schemas.corporate import (
    MIN_ABS_ESTIMATE_FOR_PCT,
    MIN_ABS_REVENUE_FOR_PCT,
    ClassificationSource,
    CorporateNewsFeed,
    CorporateNewsItem,
    EarningsCalendar,
    EarningsEvent,
    EarningsHistory,
    EarningsSession,
    EarningsStatus,
    FilingsResponse,
    FilingType,
    NewsCategory,
    NewsSentiment,
    SecFiling,
    SurpriseDirection,
)
from app.schemas.intelligence import DataAvailability
from src.ingestion.fmp_client import FMPClient
from src.ingestion.gemini_client import GeminiClient
from src.ingestion.tavily_client import TavilyClient
from src.validation.domain_models import DataStatus, EvidenceItem

logger = logging.getLogger(__name__)

# --- Motivos de degradación ----------------------------------------------------------------------

REASON_NO_FMP = "Los datos corporativos no están configurados en este entorno (falta FMP_API_KEY en .env)."
REASON_FMP_FAILED = "El proveedor de datos corporativos no respondió en este momento. Probá de nuevo en un rato."
REASON_NO_TAVILY = "El feed de noticias no está configurado en este entorno (falta TAVILY_API_KEY en .env)."
REASON_TAVILY_FAILED = (
    "El buscador de noticias no respondió en este momento. Probá de nuevo en un rato."
)
REASON_NO_GEMINI_SUMMARY = (
    "La síntesis con IA no está configurada en este entorno (falta GEMINI_API_KEY en .env); los "
    "reportes se listan con su enlace oficial."
)
REASON_GEMINI_SUMMARY_FAILED = (
    "No se pudo generar la síntesis de los reportes en este momento; los enlaces oficiales están "
    "igual."
)

# Umbral por debajo del cual un balance se considera "en línea" y no un beat/miss. Medio centavo de
# EPS no es una sorpresa: es redondeo, y marcarlo como BEAT convertiría ruido en señal.
_IN_LINE_EPS_TOLERANCE = 0.005

# Cuántos días de noticias mira el feed por defecto.
_NEWS_WINDOW_DAYS = 14

_MAX_CACHE_ENTRIES = 128


# --- Clasificación de noticias --------------------------------------------------------------------
#
# Palabras clave en minúsculas, sin acentos resueltos aparte: el título se normaliza antes de
# buscarlas. El orden de evaluación de las categorías IMPORTA y está fijado abajo.

_RUMOR_KEYWORDS = (
    "rumor",
    "rumour",
    "reportedly",
    "según fuentes",
    "segun fuentes",
    "fuentes cercanas",
    "people familiar",
    "sources say",
    "trascendio",
    "trascendió",
    "en negociaciones",
    "in talks",
    "explorando",
    "exploring a",
    "podria adquirir",
    "podría adquirir",
    "weighing",
)

_EARNINGS_KEYWORDS = (
    "earnings",
    "balance",
    "resultados",
    "quarterly",
    "trimestre",
    "eps",
    "guidance",
    "revenue beat",
    "profit",
    "ganancias",
    "facturacion",
    "facturación",
)

_REGULATORY_KEYWORDS = (
    "sec ",
    "regulator",
    "regulador",
    "antitrust",
    "antimonopolio",
    "lawsuit",
    "demanda",
    "investigation",
    "investigacion",
    "investigación",
    "fine",
    "multa",
    "sanction",
    "sancion",
    "sanción",
    "subpoena",
    "ftc",
    "doj",
    "compliance",
    "ban",
    "prohibicion",
    "prohibición",
    "export control",
    "arancel",
    "tariff",
)

_CORPORATE_KEYWORDS = (
    "acquisition",
    "adquisicion",
    "adquisición",
    "merger",
    "fusion",
    "fusión",
    "ceo",
    "cfo",
    "board",
    "directorio",
    "layoff",
    "despido",
    "dividend",
    "dividendo",
    "buyback",
    "recompra",
    "spin-off",
    "partnership",
    "alianza",
    "launch",
    "lanzamiento",
    "contract",
    "contrato",
    "expansion",
    "expansión",
)

_BULLISH_KEYWORDS = (
    "beat",
    "supera",
    "superó",
    "supero",
    "record",
    "récord",
    "surge",
    "soars",
    "rally",
    "upgrade",
    "raises",
    "eleva",
    "growth",
    "crecimiento",
    "profit jump",
    "gains",
    "sube",
    "alza",
    "strong demand",
    "fuerte demanda",
    "approval",
    "aprobacion",
    "aprobación",
    "buyback",
    "recompra",
    "outperform",
)

_BEARISH_KEYWORDS = (
    "miss",
    "falls short",
    "decepciona",
    "plunge",
    "plummet",
    "tumble",
    "slump",
    "downgrade",
    "cuts",
    "recorta",
    "layoff",
    "despido",
    "lawsuit",
    "demanda",
    "investigation",
    "investigacion",
    "investigación",
    "fine",
    "multa",
    "warning",
    "advertencia",
    "loss",
    "perdida",
    "pérdida",
    "caida",
    "caída",
    "baja",
    "recall",
    "delay",
    "retraso",
    "ban",
    "underperform",
)

_ACCENT_MAP = str.maketrans("áéíóúÁÉÍÓÚñÑ", "aeiouAEIOUnN")


def normalize_for_matching(text: str) -> str:
    """Baja a minúsculas y saca acentos, para que "adquisición" y "adquisicion" matcheen igual."""

    return text.translate(_ACCENT_MAP).lower()


def classify_category(title: str, summary: str | None = None) -> NewsCategory:
    """Categoría de una noticia, por palabras clave sobre el título (y el resumen si hay).

    **El orden es la regla, no un detalle de implementación:**

      1. `RUMOR` gana sobre todo lo demás. Una versión sin confirmar sobre una adquisición es antes
         un rumor que una noticia corporativa, y mezclarla con los hechos confirmados es
         precisamente el error que esta categoría existe para evitar.
      2. `REGULATORY` gana sobre `EARNINGS` y `CORPORATE`: una demanda de la SEC sobre el reporte
         trimestral es un problema regulatorio, no un balance.
      3. `EARNINGS` gana sobre `CORPORATE` porque es más específica.
      4. `MARKET` es el resto — explícito, no un `None` disfrazado.
    """

    haystack = normalize_for_matching(f"{title} {summary or ''}")

    if any(keyword in haystack for keyword in _map_keywords(_RUMOR_KEYWORDS)):
        return NewsCategory.RUMOR
    if any(keyword in haystack for keyword in _map_keywords(_REGULATORY_KEYWORDS)):
        return NewsCategory.REGULATORY
    if any(keyword in haystack for keyword in _map_keywords(_EARNINGS_KEYWORDS)):
        return NewsCategory.EARNINGS
    if any(keyword in haystack for keyword in _map_keywords(_CORPORATE_KEYWORDS)):
        return NewsCategory.CORPORATE
    return NewsCategory.MARKET


def classify_sentiment(title: str, summary: str | None = None) -> NewsSentiment:
    """Sentimiento por conteo de coincidencias.

    Se cuentan las dos listas y gana la mayor; un empate —incluido el empate en cero— da `NEUTRAL`.
    Empatar hacia neutral es deliberado: un titular con señales en las dos direcciones ("recorta
    costos y supera estimaciones") no es alcista ni bajista, y forzarlo a un lado sería inventar una
    conclusión que el texto no da.

    Solo el título y el resumen: no se lee la nota completa ni se pondera la fuente. Es un heurístico
    y el contrato lo declara con `classification_source=KEYWORD`.
    """

    haystack = normalize_for_matching(f"{title} {summary or ''}")
    bullish = sum(1 for word in _map_keywords(_BULLISH_KEYWORDS) if word in haystack)
    bearish = sum(1 for word in _map_keywords(_BEARISH_KEYWORDS) if word in haystack)

    if bullish > bearish:
        return NewsSentiment.BULLISH
    if bearish > bullish:
        return NewsSentiment.BEARISH
    return NewsSentiment.NEUTRAL


def _map_keywords(keywords: tuple[str, ...]) -> tuple[str, ...]:
    return tuple(normalize_for_matching(word) for word in keywords)


# --- Normalización de balances ---------------------------------------------------------------------


def compute_surprise(
    estimated: float | None,
    actual: float | None,
    *,
    min_abs_estimate: float,
) -> tuple[float | None, float | None]:
    """Diferencia absoluta y porcentual entre lo reportado y lo estimado.

    El porcentaje es `None` cuando el estimado está por debajo de `min_abs_estimate`. Es la decisión
    más importante de esta función: `(0.05 − (−0.01)) / 0.01` da 600%, un número que existe pero no
    significa nada — la empresa no superó las expectativas en 600%, es que la base era ruido. Un
    porcentaje enorme en la UI se lee como una sorpresa histórica.

    La diferencia absoluta SÍ se devuelve en ese caso: "reportó 6 centavos más de lo esperado" es una
    afirmación verdadera y útil, aunque el cociente no lo sea.
    """

    if estimated is None or actual is None:
        return None, None

    surprise = actual - estimated
    # El piso es inclusivo a propósito: con `<`, un estimado de exactamente un centavo pasa el
    # filtro y produce el 600% del ejemplo de arriba, que es justo lo que esta función evita.
    if abs(estimated) <= min_abs_estimate:
        return surprise, None
    return surprise, (surprise / abs(estimated)) * 100.0


def classify_direction(eps_surprise: float | None) -> SurpriseDirection:
    """BEAT/MISS/IN_LINE sobre la sorpresa de EPS.

    Medio centavo de tolerancia: por debajo de eso es redondeo, y marcarlo como BEAT convertiría
    ruido en señal en una pantalla que el usuario mira para decidir.
    """

    if eps_surprise is None:
        return SurpriseDirection.UNKNOWN
    if eps_surprise > _IN_LINE_EPS_TOLERANCE:
        return SurpriseDirection.BEAT
    if eps_surprise < -_IN_LINE_EPS_TOLERANCE:
        return SurpriseDirection.MISS
    return SurpriseDirection.IN_LINE


_SESSION_ALIASES = {
    "bmo": EarningsSession.BMO,
    "before market open": EarningsSession.BMO,
    "pre-market": EarningsSession.BMO,
    "premarket": EarningsSession.BMO,
    "amc": EarningsSession.AMC,
    "after market close": EarningsSession.AMC,
    "post-market": EarningsSession.AMC,
    "aftermarket": EarningsSession.AMC,
    "dmh": EarningsSession.DURING,
    "during market hours": EarningsSession.DURING,
}


def parse_session(raw: Any) -> EarningsSession:
    """Horario del reporte. Lo que no se reconoce cae a `UNKNOWN`, nunca a un default optimista:
    suponer BMO haría que alguien planifique una operación para la apertura sobre un dato inventado.
    """

    if not isinstance(raw, str):
        return EarningsSession.UNKNOWN
    return _SESSION_ALIASES.get(raw.strip().lower(), EarningsSession.UNKNOWN)


_FILING_TYPE_ALIASES = {
    "10-K": FilingType.TEN_K,
    "10K": FilingType.TEN_K,
    "10-Q": FilingType.TEN_Q,
    "10Q": FilingType.TEN_Q,
    "8-K": FilingType.EIGHT_K,
    "8K": FilingType.EIGHT_K,
}


def parse_filing_type(raw: str | None) -> FilingType:
    """Normaliza el tipo de reporte.

    Una enmienda ("10-K/A") NO se normaliza a `10-K`: es un documento distinto, y el `raw_type` del
    schema conserva la forma exacta para que la UI pueda mostrarla. Acá cae a `OTHER`, que es
    honesto: el producto todavía no le da tratamiento propio.
    """

    if raw is None:
        return FilingType.OTHER
    return _FILING_TYPE_ALIASES.get(raw.strip().upper(), FilingType.OTHER)


def _as_float(raw: Any) -> float | None:
    if isinstance(raw, bool) or raw is None:
        return None
    if isinstance(raw, (int, float)):
        value = float(raw)
        return value if _is_finite(value) else None
    if isinstance(raw, str):
        try:
            value = float(raw.strip())
        except ValueError:
            return None
        return value if _is_finite(value) else None
    return None


def _is_finite(value: float) -> bool:
    return math.isfinite(value)


def _parse_date(raw: Any) -> date | None:
    if isinstance(raw, str) and raw:
        for fmt in ("%Y-%m-%d", "%Y-%m-%d %H:%M:%S"):
            try:
                # Se ancla a UTC y se toma la fecha: el proveedor manda la fecha de la rueda sin
                # zona, y dejarla naive haría que `.date()` dependa de dónde corre el servidor.
                return (
                    datetime.strptime(raw[:19], fmt).replace(tzinfo=timezone.utc).date()
                )
            except ValueError:
                continue
    return None


def _first(payload: dict[str, Any], keys: tuple[str, ...]) -> Any:
    for key in keys:
        if key in payload and payload[key] is not None:
            return payload[key]
    return None


_TICKER_KEYS = ("symbol", "ticker")
_DATE_KEYS = ("date", "reportDate", "fiscalDateEnding")
_SESSION_KEYS = ("time", "session", "reportTime")
_EPS_EST_KEYS = ("epsEstimated", "estimatedEps", "eps_estimated")
_EPS_ACT_KEYS = ("eps", "epsActual", "actualEps")
_REV_EST_KEYS = ("revenueEstimated", "estimatedRevenue")
_REV_ACT_KEYS = ("revenue", "revenueActual", "actualRevenue")
_PERIOD_KEYS = ("period", "fiscalPeriod", "quarter")
_PERIOD_END_KEYS = ("fiscalDateEnding", "periodEnding", "fiscalPeriodEnd")


def build_earnings_event(row: dict[str, Any]) -> EarningsEvent | None:
    """Convierte una fila cruda del proveedor en un evento.

    Devuelve `None` cuando falta el símbolo o la fecha: un balance sin ninguno de los dos no se puede
    ubicar en un calendario, y colarlo con un placeholder ensuciaría la lista con filas que el
    usuario no puede usar.
    """

    ticker = _first(row, _TICKER_KEYS)
    event_date = _parse_date(_first(row, _DATE_KEYS))
    if not isinstance(ticker, str) or not ticker.strip() or event_date is None:
        return None

    eps_estimated = _as_float(_first(row, _EPS_EST_KEYS))
    eps_actual = _as_float(_first(row, _EPS_ACT_KEYS))
    revenue_estimated = _as_float(_first(row, _REV_EST_KEYS))
    revenue_actual = _as_float(_first(row, _REV_ACT_KEYS))

    eps_surprise, eps_surprise_pct = compute_surprise(
        eps_estimated, eps_actual, min_abs_estimate=MIN_ABS_ESTIMATE_FOR_PCT
    )
    revenue_surprise, revenue_surprise_pct = compute_surprise(
        revenue_estimated, revenue_actual, min_abs_estimate=MIN_ABS_REVENUE_FOR_PCT
    )

    period = _first(row, _PERIOD_KEYS)
    has_actuals = eps_actual is not None or revenue_actual is not None

    return EarningsEvent(
        ticker=ticker.strip().upper(),
        company_name=_clean_str(row.get("name")),
        event_date=event_date,
        session=parse_session(_first(row, _SESSION_KEYS)),
        # El estado sale de si HAY números reportados, no de si la fecha ya pasó: un balance de ayer
        # sin datos cargados sigue siendo "programado" para el usuario, porque no hay nada que leer.
        status=EarningsStatus.REPORTED if has_actuals else EarningsStatus.SCHEDULED,
        fiscal_period=_clean_str(period) if isinstance(period, str) else None,
        fiscal_period_end=_parse_date(_first(row, _PERIOD_END_KEYS)),
        eps_estimated=eps_estimated,
        eps_actual=eps_actual,
        eps_surprise=eps_surprise,
        eps_surprise_pct=eps_surprise_pct,
        revenue_estimated=revenue_estimated,
        revenue_actual=revenue_actual,
        revenue_surprise=revenue_surprise,
        revenue_surprise_pct=revenue_surprise_pct,
        surprise_direction=classify_direction(eps_surprise),
    )


def _clean_str(raw: Any) -> str | None:
    if not isinstance(raw, str):
        return None
    return raw.strip() or None


def summarize_history(
    quarters: list[EarningsEvent],
) -> tuple[int, int, int, int, float | None]:
    """Estadística agregada del histórico: (beats, misses, en línea, medidos, promedio %).

    Solo entran los trimestres con dirección conocida. Un trimestre sin estimación no se puede contar
    ni como acierto ni como fallo, y meterlo en el denominador diluiría la tasa de aciertos hacia
    abajo — haría parecer menos consistente a una empresa por un hueco del proveedor.
    """

    beats = sum(1 for q in quarters if q.surprise_direction is SurpriseDirection.BEAT)
    misses = sum(1 for q in quarters if q.surprise_direction is SurpriseDirection.MISS)
    in_line = sum(
        1 for q in quarters if q.surprise_direction is SurpriseDirection.IN_LINE
    )
    measured = beats + misses + in_line

    percentages = [
        q.eps_surprise_pct for q in quarters if q.eps_surprise_pct is not None
    ]
    average = sum(percentages) / len(percentages) if percentages else None
    return beats, misses, in_line, measured, average


def news_ref_id(url: str | None, title: str) -> str:
    """Identificador estable de una noticia.

    Se deriva de la URL porque es lo único estable que da el proveedor: Tavily no manda id, y el
    título de una misma nota cambia entre ediciones. Sin URL cae al título — peor, pero mejor que un
    id aleatorio que rompería el "ya leído" del cliente en cada refresco.
    """

    digest = hashlib.sha256((url or title).encode("utf-8")).hexdigest()
    return f"news-{digest[:16]}"


def extract_source(url: str | None) -> str | None:
    """Dominio de la publicación, sin `www.`."""

    if not url:
        return None
    host = urlparse(url).netloc.strip().lower()
    if not host:
        return None
    return host.removeprefix("www.")


# --- Caché ------------------------------------------------------------------------------------------


class _TtlCache:
    """Caché por TTL con desalojo por orden de inserción.

    `time.monotonic` y no `datetime.now`: mide tiempo transcurrido, y un ajuste del reloj del sistema
    no debería invalidarla ni eternizarla.

    El `Lock` NO es para proteger el `dict` (el GIL alcanza), sino para que dos requests simultáneos
    por la misma clave no disparen dos veces la llamada al proveedor. Con un feed de noticias abierto
    en dos pestañas eso es el caso normal, no el raro.
    """

    def __init__(
        self, *, ttl_seconds: float, max_entries: int = _MAX_CACHE_ENTRIES
    ) -> None:
        self._ttl = ttl_seconds
        self._max_entries = max_entries
        self._entries: dict[str, tuple[float, Any]] = {}
        self._locks: dict[str, asyncio.Lock] = {}

    def get(self, key: str) -> Any | None:
        entry = self._entries.get(key)
        if entry is None:
            return None
        stored_at, value = entry
        if time.monotonic() - stored_at > self._ttl:
            del self._entries[key]
            return None
        return value

    def set(self, key: str, value: Any) -> None:
        if len(self._entries) >= self._max_entries:
            oldest = next(iter(self._entries))
            del self._entries[oldest]
        self._entries[key] = (time.monotonic(), value)

    def lock_for(self, key: str) -> asyncio.Lock:
        lock = self._locks.get(key)
        if lock is None:
            lock = asyncio.Lock()
            self._locks[key] = lock
            # Los locks se podan junto con las entradas para que la tabla no crezca sin límite con
            # claves que nunca se repiten (un ticker distinto por consulta). Un lock TOMADO no se
            # poda aunque su clave no esté cacheada: es el de un request en vuelo, y sacarlo del
            # diccionario dejaría que el siguiente cree otro y llame al proveedor en paralelo, que
            # es exactamente lo que el lock existe para evitar.
            if len(self._locks) > self._max_entries * 2:
                for stale, stale_lock in list(self._locks.items()):
                    if (
                        stale != key
                        and stale not in self._entries
                        and not stale_lock.locked()
                    ):
                        del self._locks[stale]
        return lock

    def clear(self) -> None:
        self._entries.clear()


# --- Servicio ----------------------------------------------------------------------------------------


class CorporateService:
    """Los tres clientes son opcionales y `None` es un estado válido: el servicio se instancia igual
    y cada vista degrada la suya. Exigirlos en el constructor obligaría a no registrar el módulo en
    un entorno sin credenciales, que es justo donde la degradación tiene que verse.
    """

    def __init__(
        self,
        *,
        fmp_client: FMPClient | None = None,
        tavily_client: TavilyClient | None = None,
        gemini_client: GeminiClient | None = None,
        calendar_ttl_seconds: float = 3600.0,
        history_ttl_seconds: float = 21600.0,
        filings_ttl_seconds: float = 3600.0,
        news_ttl_seconds: float = 900.0,
        max_news_results: int = 20,
        max_filings: int = 20,
        system_prompt: str | None = None,
    ) -> None:
        self._fmp = fmp_client
        self._tavily = tavily_client
        self._gemini = gemini_client
        self._max_news_results = max_news_results
        self._max_filings = max_filings
        self._system_prompt = system_prompt or _DEFAULT_SUMMARY_PROMPT

        # Un TTL por vista, no uno global: un calendario de balances cambia de hora en hora y un
        # histórico de trimestres cerrados no cambia en meses. Un TTL único obligaría a elegir entre
        # gastar llamadas de más o servir datos viejos.
        self._calendar_cache = _TtlCache(ttl_seconds=calendar_ttl_seconds)
        self._history_cache = _TtlCache(ttl_seconds=history_ttl_seconds)
        self._filings_cache = _TtlCache(ttl_seconds=filings_ttl_seconds)
        self._news_cache = _TtlCache(ttl_seconds=news_ttl_seconds)

    # --- Calendario de balances -------------------------------------------------------------

    async def get_earnings_calendar(
        self,
        *,
        from_date: date,
        to_date: date,
        ticker: str | None = None,
        sector_tickers: frozenset[str] | None = None,
    ) -> EarningsCalendar:
        """Balances del rango, filtrables por símbolo o por sector.

        `sector_tickers` llega YA resuelto por el endpoint desde el catálogo local, no se resuelve
        acá: pedirle el sector al proveedor por cada símbolo del calendario serían decenas de
        requests dentro de un request HTTP, y el catálogo propio ya tiene el dato.
        """

        if (fmp := self._fmp) is None:
            return EarningsCalendar(
                from_date=from_date,
                to_date=to_date,
                availability=DataAvailability.UNAVAILABLE,
                degradation_reason=REASON_NO_FMP,
            )

        # La caché guarda el rango COMPLETO sin filtrar, y los filtros se aplican después. Así,
        # mirar "toda la semana" y después "solo NVDA" es una sola llamada al proveedor.
        key = f"{from_date.isoformat()}:{to_date.isoformat()}"
        cached = self._calendar_cache.get(key)
        from_cache = cached is not None

        if cached is None:
            async with self._calendar_cache.lock_for(key):
                cached = self._calendar_cache.get(key)
                from_cache = cached is not None
                if cached is None:
                    rows, status = await fmp.get_earnings_calendar(from_date, to_date)
                    if status != DataStatus.OK:
                        return EarningsCalendar(
                            from_date=from_date,
                            to_date=to_date,
                            availability=DataAvailability.UNAVAILABLE,
                            degradation_reason=REASON_FMP_FAILED,
                        )
                    cached = [
                        event
                        for event in (build_earnings_event(row) for row in rows)
                        if event is not None
                        # Se descarta lo que cae AFUERA del rango pedido, aunque el proveedor lo haya
                        # mandado. La respuesta declara `from_date`/`to_date`, y una fila del 27/08
                        # debajo de un encabezado que dice "10/08 — 17/08" hace que la pantalla se
                        # contradiga: el rango de la respuesta es la afirmación, no una sugerencia.
                        and from_date <= event.event_date <= to_date
                    ]
                    self._calendar_cache.set(key, cached)

        events: list[EarningsEvent] = list(cached)
        unclassified = 0

        if ticker:
            wanted = ticker.strip().upper()
            events = [event for event in events if event.ticker == wanted]
        elif sector_tickers is not None:
            # Un símbolo que no está en el catálogo local NO entra: sin su sector no se puede afirmar
            # que pertenezca al que se pidió. Se cuenta para poder decirlo en la respuesta.
            kept = [event for event in events if event.ticker in sector_tickers]
            unclassified = len(events) - len(kept)
            events = kept

        events.sort(key=lambda event: (event.event_date, event.ticker))

        return EarningsCalendar(
            from_date=from_date,
            to_date=to_date,
            events=events,
            availability=DataAvailability.AVAILABLE,
            served_from_cache=from_cache,
            unclassified_by_sector=unclassified,
        )

    # --- Histórico de sorpresas -------------------------------------------------------------

    async def get_earnings_history(
        self, ticker: str, *, limit: int = 8
    ) -> EarningsHistory:
        symbol = ticker.strip().upper()
        if (fmp := self._fmp) is None:
            return EarningsHistory(
                ticker=symbol,
                availability=DataAvailability.UNAVAILABLE,
                degradation_reason=REASON_NO_FMP,
            )

        key = f"{symbol}:{limit}"
        cached = self._history_cache.get(key)
        if cached is not None:
            return cached.model_copy(update={"served_from_cache": True})

        async with self._history_cache.lock_for(key):
            cached = self._history_cache.get(key)
            if cached is not None:
                return cached.model_copy(update={"served_from_cache": True})

            rows, status = await fmp.get_earnings_history(symbol, limit=limit)
            if status != DataStatus.OK:
                return EarningsHistory(
                    ticker=symbol,
                    availability=DataAvailability.UNAVAILABLE,
                    degradation_reason=REASON_FMP_FAILED,
                )

            quarters = [
                event
                for event in (build_earnings_event(row) for row in rows)
                if event is not None and event.has_actuals
            ]
            # Del más reciente al más viejo: es el orden en que se lee un track record.
            quarters.sort(key=lambda event: event.event_date, reverse=True)

            beats, misses, in_line, measured, average = summarize_history(quarters)
            history = EarningsHistory(
                ticker=symbol,
                quarters=quarters,
                beat_count=beats,
                miss_count=misses,
                in_line_count=in_line,
                measured_quarters=measured,
                average_surprise_pct=average,
                availability=DataAvailability.AVAILABLE,
            )
            self._history_cache.set(key, history)
            return history

    # --- Reportes SEC -------------------------------------------------------------------------

    async def get_filings(
        self, ticker: str, *, limit: int = 10, summarize: bool = False
    ) -> FilingsResponse:
        """Biblioteca de reportes, con síntesis opcional.

        La síntesis es opt-in porque cuesta una llamada al modelo: abrir la biblioteca de una empresa
        para ver qué presentó no debería gastarla, y quien la quiere la pide.
        """

        symbol = ticker.strip().upper()
        if (fmp := self._fmp) is None:
            return FilingsResponse(
                ticker=symbol,
                availability=DataAvailability.UNAVAILABLE,
                degradation_reason=REASON_NO_FMP,
            )

        capped = min(limit, self._max_filings)
        key = f"{symbol}:{capped}"
        cached = self._filings_cache.get(key)
        from_cache = cached is not None

        if cached is None:
            async with self._filings_cache.lock_for(key):
                cached = self._filings_cache.get(key)
                from_cache = cached is not None
                if cached is None:
                    references, status = await fmp.list_recent_filings_with_status(
                        symbol, limit=capped
                    )
                    if status != DataStatus.OK:
                        # Lista vacía por un fallo del proveedor: se declara y NO se cachea. Devolver
                        # `AVAILABLE` acá diría "esta empresa no presentó nada ante la SEC", que de
                        # una empresa que cotiza es falso.
                        return FilingsResponse(
                            ticker=symbol,
                            availability=DataAvailability.UNAVAILABLE,
                            degradation_reason=REASON_FMP_FAILED,
                        )
                    cached = [
                        SecFiling(
                            ticker=symbol,
                            filing_type=parse_filing_type(reference.filing_type),
                            raw_type=reference.filing_type,
                            filed_at=reference.filed_at or reference.accepted_at,
                            url=reference.filing_url,
                            final_document_url=reference.final_document_url,
                        )
                        for reference in references
                    ]
                    self._filings_cache.set(key, cached)

        filings: list[SecFiling] = [filing.model_copy() for filing in cached]

        if not summarize:
            return FilingsResponse(
                ticker=symbol,
                filings=filings,
                availability=DataAvailability.AVAILABLE,
                served_from_cache=from_cache,
            )

        summary_reason = await self._attach_summaries(symbol, filings)
        return FilingsResponse(
            ticker=symbol,
            filings=filings,
            availability=DataAvailability.AVAILABLE,
            summary_degradation_reason=summary_reason,
            served_from_cache=from_cache,
        )

    async def _attach_summaries(
        self, ticker: str, filings: list[SecFiling]
    ) -> str | None:
        """Rellena `summary` en cada reporte. Devuelve el motivo si no se pudo.

        La síntesis se hace sobre los METADATOS (tipo, fecha, enlace), no sobre el texto del reporte:
        el backend no descarga los PDF de la SEC. Eso limita lo que puede decir, y por eso el prompt
        le pide contexto de qué es cada tipo de reporte y qué buscar adentro — no un resumen de un
        contenido que no vio. Pedirle lo segundo sería pedirle que invente.
        """

        if not filings:
            return None
        if (gemini := self._gemini) is None:
            return REASON_NO_GEMINI_SUMMARY

        result = await gemini.generate_structured_json(
            system_instruction=self._system_prompt,
            user_content=_build_filings_prompt(ticker, filings),
            response_schema=_SUMMARY_SCHEMA,
        )
        if result.status != DataStatus.OK or result.raw_json_text is None:
            logger.warning("corporate_filings_summary_failed", extra={"ticker": ticker})
            return REASON_GEMINI_SUMMARY_FAILED

        summaries = _parse_summaries(result.raw_json_text)
        if summaries is None:
            logger.warning(
                "corporate_filings_summary_invalid", extra={"ticker": ticker}
            )
            return REASON_GEMINI_SUMMARY_FAILED

        matched = 0
        for index, filing in enumerate(filings):
            text = summaries.get(index)
            if text:
                filing.summary = text
                filing.summary_available = True
                matched += 1

        if matched == 0:
            # El modelo respondió con forma válida pero sin sintetizar nada. Se trata como una falla
            # en vez de devolver una lista con todos los `summary` vacíos y `available=True`.
            return REASON_GEMINI_SUMMARY_FAILED
        return None

    # --- Noticias -------------------------------------------------------------------------------

    async def get_news(
        self,
        *,
        ticker: str | None = None,
        category: NewsCategory | None = None,
        sentiment: NewsSentiment | None = None,
        limit: int = 20,
    ) -> CorporateNewsFeed:
        symbol = ticker.strip().upper() if ticker else None

        if (tavily := self._tavily) is None:
            return CorporateNewsFeed(
                availability=DataAvailability.UNAVAILABLE,
                degradation_reason=REASON_NO_TAVILY,
                applied_ticker=symbol,
                applied_category=category,
                applied_sentiment=sentiment,
            )

        # La caché guarda el feed SIN filtrar por categoría/sentimiento: los dos se resuelven en
        # código sobre los mismos ítems, así que cambiar de pestaña en la UI no cuesta una búsqueda
        # nueva.
        key = symbol or "__market__"
        cached = self._news_cache.get(key)
        from_cache = cached is not None

        if cached is None:
            async with self._news_cache.lock_for(key):
                cached = self._news_cache.get(key)
                from_cache = cached is not None
                if cached is None:
                    # Se pide el tope configurado y NO el `limit` de este request: la entrada
                    # cacheada tiene que servir a cualquier `limit` posterior. Guardar el feed del
                    # primero que llamó dejaría a quien pida más items con menos, y haría que
                    # `total_before_filters` reporte un total que es el de otro request.
                    result = await tavily.search_news(
                        _build_news_query(symbol),
                        max_results=self._max_news_results,
                        days=_NEWS_WINDOW_DAYS,
                    )
                    if result.status != DataStatus.OK:
                        return CorporateNewsFeed(
                            availability=DataAvailability.UNAVAILABLE,
                            degradation_reason=REASON_TAVILY_FAILED,
                            applied_ticker=symbol,
                            applied_category=category,
                            applied_sentiment=sentiment,
                        )
                    cached = [
                        _build_news_item(article, symbol) for article in result.articles
                    ]
                    self._news_cache.set(key, cached)

        items: list[CorporateNewsItem] = list(cached)
        total_before = len(items)

        if category is not None:
            items = [item for item in items if item.category is category]
        if sentiment is not None:
            items = [item for item in items if item.sentiment is sentiment]

        # Lo más reciente primero. Los ítems sin fecha van al final en vez de al principio: no se
        # puede afirmar que una nota sin fecha sea la más nueva.
        items.sort(
            key=lambda item: (
                item.published_at or datetime.min.replace(tzinfo=timezone.utc)
            ),
            reverse=True,
        )

        return CorporateNewsFeed(
            items=items[:limit],
            availability=DataAvailability.AVAILABLE,
            served_from_cache=from_cache,
            applied_ticker=symbol,
            applied_category=category,
            applied_sentiment=sentiment,
            total_before_filters=total_before,
        )


def _build_news_query(ticker: str | None) -> str:
    if ticker:
        return (
            f"{ticker} stock news: earnings, acquisitions, regulation, rumors and "
            "corporate announcements"
        )
    return (
        "stock market corporate news: earnings, mergers, acquisitions, regulation and "
        "market-moving rumors"
    )


def _build_news_item(article: EvidenceItem, ticker: str | None) -> CorporateNewsItem:
    """Arma el ítem a partir de un `EvidenceItem` de Tavily.

    El `excerpt` es el resumen y no se re-resume con el modelo: pedirle que condense un extracto de
    dos líneas costaría una llamada por noticia para no ganar nada, y agregaría una oportunidad de
    que el resumen diga algo que la nota no dice.
    """

    excerpt = (article.excerpt or "").strip()
    url = article.url
    published_at = article.published_at

    # El titular que manda el proveedor. Recién si no viene se cae a la primera línea del cuerpo,
    # que es una oración del medio de la nota y se nota: por eso es el último recurso y no el
    # camino normal.
    title = (article.title or "").strip() or excerpt.split("\n", 1)[0][:200]
    title = title or extract_source(url) or "Noticia"
    summary = excerpt or None

    return CorporateNewsItem(
        ref_id=news_ref_id(url, title),
        title=title,
        source=extract_source(url),
        published_at=published_at,
        summary=summary,
        url=url,
        category=classify_category(title, summary),
        sentiment=classify_sentiment(title, summary),
        classification_source=ClassificationSource.KEYWORD,
        tickers=[ticker] if ticker else [],
    )


# --- Síntesis de reportes ------------------------------------------------------------------------

_DEFAULT_SUMMARY_PROMPT = """Sos un analista financiero que ayuda a un inversor minorista a
entender qué presentó una empresa ante la SEC.

Recibís una lista NUMERADA de reportes con su tipo y su fecha. NO tenés el contenido de los
documentos: solo los metadatos.

Para cada reporte escribí una síntesis de UNA o DOS oraciones en español rioplatense que explique:
  - qué tipo de documento es y para qué sirve,
  - qué información concreta debería buscar el inversor adentro,
  - por qué esa fecha puede importar (cierre de ejercicio, trimestre, hecho relevante).

REGLAS INVIOLABLES:
  - NO inventes cifras, resultados, ni conclusiones sobre la empresa. No los tenés.
  - NO afirmes qué dice el reporte. Podés decir qué SUELE contener ese tipo de reporte.
  - Si un tipo de reporte no lo reconocés, decilo en vez de suponer.

Respondé en JSON con la forma indicada, usando el mismo índice que recibiste."""

_SUMMARY_SCHEMA: dict[str, Any] = {
    "type": "OBJECT",
    "properties": {
        "summaries": {
            "type": "ARRAY",
            "items": {
                "type": "OBJECT",
                "properties": {
                    "index": {"type": "INTEGER"},
                    "summary": {"type": "STRING"},
                },
                "required": ["index", "summary"],
            },
        }
    },
    "required": ["summaries"],
}


def _build_filings_prompt(ticker: str, filings: list[SecFiling]) -> str:
    lines = [f"Empresa: {ticker}", "", "Reportes:"]
    for index, filing in enumerate(filings):
        filed = filing.filed_at.date().isoformat() if filing.filed_at else "sin fecha"
        lines.append(
            f"{index}. {filing.raw_type or filing.filing_type.value} — presentado {filed}"
        )
    return "\n".join(lines)


def _parse_summaries(raw_json_text: str) -> dict[int, str] | None:
    """Índice → síntesis. `None` si la respuesta no se puede leer.

    Se ignoran las entradas con índice fuera de rango o texto vacío en vez de descartar la respuesta
    entera: que el modelo se saltee un reporte no debería tirar los otros nueve.
    """

    try:
        parsed = json.loads(raw_json_text)
    except json.JSONDecodeError:
        return None
    if not isinstance(parsed, dict):
        return None

    entries = parsed.get("summaries")
    if not isinstance(entries, list):
        return None

    summaries: dict[int, str] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        index = entry.get("index")
        text = entry.get("summary")
        if isinstance(index, int) and isinstance(text, str) and text.strip():
            summaries[index] = text.strip()
    return summaries


def default_calendar_range(*, days_ahead: int = 7) -> tuple[date, date]:
    """Rango por defecto del calendario: desde hoy y `days_ahead` hacia adelante.

    `datetime.now(timezone.utc).date()` y no `date.today()`: el servidor puede correr en cualquier
    zona, y el calendario de balances es de mercados de EE.UU. — anclarlo a UTC lo hace reproducible.
    """

    today = datetime.now(timezone.utc).date()
    return today, today + timedelta(days=days_ahead)
