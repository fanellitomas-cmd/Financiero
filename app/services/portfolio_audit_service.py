"""Servicio de `GET/POST /api/v1/watchlist/audit` — la Auditoría de Portafolio por IA.

Compone cuatro bloques determinísticos más una narrativa:

  1. **Distribución por sector** — cruza la watchlist contra el sector de cada símbolo (catálogo
     local primero, FMP `/profile` para los que faltan, con write-through al catálogo).
  2. **Concentración de riesgo** — umbrales explícitos sobre el peso del sector dominante y el
     índice de Herfindahl. En código, no en el modelo: la misma cartera tiene que dar siempre el
     mismo veredicto.
  3. **Advertencias de correlación** — Pearson sobre retornos diarios reales de Polygon. Cuando no
     hay histórico suficiente para un par, cae a una heurística por sector marcada como tal
     (`basis=SECTOR`), nunca a un número inventado.
  4. **Sugerencias de diversificación** — sectores ausentes o subrepresentados, elegidos de una
     tabla de complementos explícita.

Y sobre eso, `ai_summary`: Gemini redacta la narrativa a partir de los cuatro bloques ya
calculados. Sin credenciales de IA el resto de la auditoría se sirve igual con
`ai_summary_available=False` (.cursorrules §2).

La caché es por usuario Y por composición de la watchlist: la clave incluye una huella de los
símbolos seguidos, así que agregar o quitar un ticker invalida la entrada sola, sin necesitar que
la API se acuerde de purgarla al modificar la watchlist.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import math
import time
from datetime import datetime, timedelta, timezone
from itertools import pairwise
from pathlib import Path
from typing import Any
from uuid import UUID

from pydantic import BaseModel, ConfigDict, ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.enums import AssetType
from app.models.watchlist import WatchlistItem
from app.schemas.intelligence import DataAvailability
from app.schemas.portfolio_audit import (
    ConcentrationRisk,
    CorrelationBasis,
    CorrelationWarning,
    DiversificationSuggestion,
    PortfolioAudit,
    PortfolioSector,
    RiskLevel,
    SectorAllocation,
    sector_label,
)
from app.services.ticker_catalog_service import TickerCatalogService
from src.ingestion.fmp_client import FMPClient
from src.ingestion.gemini_client import GeminiClient
from src.ingestion.polygon_client import PolygonClient
from src.ingestion.schemas_raw import OhlcBar
from src.validation.domain_models import DataStatus

logger = logging.getLogger(__name__)

_PROMPT_PATH = (
    Path(__file__).resolve().parent.parent.parent
    / "prompts"
    / "portfolio_audit_system_prompt.md"
)

_REASON_EMPTY_WATCHLIST = (
    "Todavía no seguís ningún activo. Agregá al menos dos a tu watchlist para que la auditoría "
    "pueda medir concentración y correlaciones."
)
_REASON_SINGLE_POSITION = (
    "Con un solo activo no hay diversificación que auditar: toda la cartera está concentrada en "
    "él por definición."
)
_REASON_NO_SECTOR_SOURCE = (
    "La clasificación por sector no está configurada en este entorno (falta FMP_API_KEY en .env) "
    "y el catálogo local todavía no tiene el sector de estos símbolos."
)
_REASON_PARTIAL_SECTORS = (
    "No se pudo determinar el sector de todos los activos; los que faltan figuran como "
    "'Sin clasificar' y se cuentan aparte en la concentración."
)
_REASON_NO_GEMINI = (
    "La narrativa con IA no está configurada en este entorno (falta GEMINI_API_KEY en .env); la "
    "distribución, la concentración y las advertencias son cálculos propios y son datos reales."
)
_REASON_GEMINI_FAILED = (
    "No se pudo generar la narrativa con IA en este momento (falló la consulta al modelo); el "
    "resto de la auditoría son cálculos propios sobre tu watchlist."
)
_REASON_GEMINI_INVALID = (
    "El modelo devolvió una narrativa que no se pudo interpretar; el resto de la auditoría son "
    "cálculos propios sobre tu watchlist."
)

# Vocabulario de FMP -> vocabulario del producto. Las claves se comparan en minúsculas y sin
# espacios de sobra, así que `Financial Services` y `financial services` caen en el mismo lugar.
#
# Un sector que no esté en esta tabla NO se descarta ni se adivina: cae en `SIN_CLASIFICAR` y queda
# visible en la auditoría, que es la señal de que hay que agregarlo acá.
_SECTOR_TRANSLATIONS: dict[str, PortfolioSector] = {
    "technology": PortfolioSector.TECNOLOGIA,
    "information technology": PortfolioSector.TECNOLOGIA,
    "healthcare": PortfolioSector.SALUD,
    "health care": PortfolioSector.SALUD,
    "financial services": PortfolioSector.SERVICIOS_FINANCIEROS,
    "financials": PortfolioSector.SERVICIOS_FINANCIEROS,
    "financial": PortfolioSector.SERVICIOS_FINANCIEROS,
    "consumer cyclical": PortfolioSector.CONSUMO_DISCRECIONAL,
    "consumer discretionary": PortfolioSector.CONSUMO_DISCRECIONAL,
    "consumer defensive": PortfolioSector.CONSUMO_BASICO,
    "consumer staples": PortfolioSector.CONSUMO_BASICO,
    "industrials": PortfolioSector.INDUSTRIA,
    "industrial goods": PortfolioSector.INDUSTRIA,
    "energy": PortfolioSector.ENERGIA,
    "basic materials": PortfolioSector.MATERIALES,
    "materials": PortfolioSector.MATERIALES,
    "utilities": PortfolioSector.SERVICIOS_PUBLICOS,
    "real estate": PortfolioSector.BIENES_RAICES,
    "communication services": PortfolioSector.COMUNICACIONES,
    "telecommunication": PortfolioSector.COMUNICACIONES,
}

# Sectores que se ofrecen como contrapeso, en orden de preferencia. Los tres primeros son los
# defensivos clásicos: históricamente son los que menos se mueven con el ciclo de las tecnológicas,
# que es la concentración más común en una cartera de retail.
#
# Es una tabla explícita y opinable a propósito, no una correlación calculada: para calcular qué
# sector descorrelaciona harían falta series de índices sectoriales que el sistema no ingesta. Se
# deja el criterio visible para que se pueda discutir, en vez de esconderlo en un número.
_COMPLEMENT_SECTORS: tuple[PortfolioSector, ...] = (
    PortfolioSector.SALUD,
    PortfolioSector.CONSUMO_BASICO,
    PortfolioSector.SERVICIOS_PUBLICOS,
    PortfolioSector.INDUSTRIA,
    PortfolioSector.ENERGIA,
    PortfolioSector.SERVICIOS_FINANCIEROS,
    PortfolioSector.MATERIALES,
    PortfolioSector.BIENES_RAICES,
    PortfolioSector.SALUD,
)

_SUGGESTIONS_TARGET = 3
# Un sector con menos de este peso cuenta como "subrepresentado" y puede sugerirse igual: tener un
# solo activo de Salud en una cartera de 10 no es estar diversificado en Salud.
_UNDERWEIGHT_PCT = 10.0
_MAX_CORRELATION_WARNINGS = 6

_RESPONSE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {"summary": {"type": "string"}},
    "required": ["summary"],
}


class _LLMAuditOutput(BaseModel):
    """Forma exacta de lo que se le pide al LLM: solo la prosa.

    Ni el nivel de riesgo, ni los porcentajes, ni las advertencias — todo eso ya está calculado
    cuando se lo llama. Si el modelo también los devolviera, habría dos versiones del mismo número
    en la respuesta y la del modelo podría no coincidir.
    """

    model_config = ConfigDict(strict=True, extra="ignore")

    summary: str


def _load_system_prompt() -> str:
    try:
        return _PROMPT_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(
            f"No se pudo leer el system prompt de la auditoría de portafolio en {_PROMPT_PATH}."
        ) from exc


def provider_sector_keys(sector: PortfolioSector) -> list[str]:
    """Camino inverso de `normalize_sector`: qué nombres del proveedor caen en este sector del
    producto, en minúsculas.

    Lo usa la búsqueda en lenguaje natural para filtrar el catálogo, que guarda el sector CRUDO
    (`Technology`), a partir de un criterio del producto (`TECNOLOGIA`). Se deriva de la misma
    tabla que la traducción de ida, así que agregar un alias nuevo sirve para las dos direcciones
    sin poder desincronizarlas.

    Devuelve vacío para `CRIPTO` y `SIN_CLASIFICAR`: ninguno de los dos existe en el vocabulario
    del proveedor de acciones — el primero se asigna por tipo de activo y el segundo es la
    ausencia de sector.
    """

    return [raw for raw, mapped in _SECTOR_TRANSLATIONS.items() if mapped is sector]


def normalize_sector(raw: str | None) -> PortfolioSector:
    """Sector crudo del proveedor -> sector del producto. `None` y lo desconocido caen en
    `SIN_CLASIFICAR`, nunca en un sector plausible: adivinarle el sector a un símbolo desconocido
    contaminaría el cálculo de concentración con una afirmación inventada.
    """

    if raw is None:
        return PortfolioSector.SIN_CLASIFICAR
    return _SECTOR_TRANSLATIONS.get(raw.strip().lower(), PortfolioSector.SIN_CLASIFICAR)


# --- Bloques determinísticos ----------------------------------------------------------------


def build_sector_allocation(
    sectors: dict[str, PortfolioSector],
) -> list[SectorAllocation]:
    """Distribución equiponderada por cantidad de activos, de mayor a menor peso.

    Equiponderada porque la watchlist no guarda cantidades (ver el docstring de
    `app/schemas/portfolio_audit.py`). El empate se rompe por nombre de sector para que dos
    corridas de la misma cartera devuelvan el mismo orden — un orden que baila haría que la UI
    reordene la torta sin que nada haya cambiado.
    """

    total = len(sectors)
    if total == 0:
        return []

    grouped: dict[PortfolioSector, list[str]] = {}
    for ticker, sector in sorted(sectors.items()):
        grouped.setdefault(sector, []).append(ticker)

    allocations = [
        SectorAllocation(
            sector=sector,
            label=sector_label(sector),
            weight_pct=round(len(tickers) / total * 100, 2),
            ticker_count=len(tickers),
            tickers=tickers,
        )
        for sector, tickers in grouped.items()
    ]
    allocations.sort(key=lambda item: (-item.weight_pct, item.sector.value))
    return allocations


def _level_from_top_weight(top_weight_pct: float) -> RiskLevel:
    if top_weight_pct >= 70:
        return RiskLevel.CRITICA
    if top_weight_pct >= 50:
        return RiskLevel.ALTA
    if top_weight_pct >= 35:
        return RiskLevel.MODERADA
    return RiskLevel.BAJA


def _level_from_herfindahl(index: float) -> RiskLevel:
    if index >= 0.60:
        return RiskLevel.CRITICA
    if index >= 0.40:
        return RiskLevel.ALTA
    if index >= 0.25:
        return RiskLevel.MODERADA
    return RiskLevel.BAJA


_RISK_ORDER: dict[RiskLevel, int] = {
    RiskLevel.BAJA: 0,
    RiskLevel.MODERADA: 1,
    RiskLevel.ALTA: 2,
    RiskLevel.CRITICA: 3,
}

_RISK_HEADLINE_WORDS: dict[RiskLevel, str] = {
    RiskLevel.BAJA: "riesgo bajo",
    RiskLevel.MODERADA: "riesgo moderado",
    RiskLevel.ALTA: "riesgo alto",
    RiskLevel.CRITICA: "riesgo muy alto",
}


def build_concentration_risk(
    allocations: list[SectorAllocation],
) -> ConcentrationRisk | None:
    """Veredicto de concentración a partir de la distribución ya calculada.

    Dos medidas y no una, tomando la PEOR de las dos: el peso del sector dominante y el índice de
    Herfindahl. Cada una sola tiene un punto ciego — una cartera 34/33/33 tiene un dominante
    inofensivo y es igual una cartera de tres sectores, y una cartera con 12 sectores donde uno pesa
    40% no está mal repartida. Mirar las dos evita firmar "riesgo bajo" en los dos casos.

    Devuelve `None` para una cartera vacía: no hay concentración que medir donde no hay activos.
    """

    if not allocations:
        return None

    top = allocations[0]
    weights = [allocation.weight_pct / 100 for allocation in allocations]
    herfindahl = sum(weight * weight for weight in weights)

    level = max(
        _level_from_top_weight(top.weight_pct),
        _level_from_herfindahl(herfindahl),
        key=lambda value: _RISK_ORDER[value],
    )

    notes: list[str] = []
    distinct = len(allocations)
    total_positions = sum(allocation.ticker_count for allocation in allocations)

    if distinct == 1:
        notes.append(
            f"Los {total_positions} activos que seguís pertenecen al mismo sector: no hay "
            "diversificación sectorial."
        )
    elif distinct == 2:
        notes.append(
            "Toda la cartera se reparte entre dos sectores; un shock que afecte a uno de los dos "
            "mueve la mitad de la lista."
        )

    if total_positions < 3:
        # Se avisa en vez de bajarle el nivel: 100% en un sector con dos activos ES concentración
        # máxima, pero el veredicto dice más sobre el tamaño de la lista que sobre el criterio de
        # quien la armó, y conviene decirlo.
        notes.append(
            "La lista todavía es corta, así que el nivel refleja sobre todo su tamaño: con pocos "
            "activos cualquier cartera aparece concentrada."
        )

    unclassified = next(
        (
            allocation
            for allocation in allocations
            if allocation.sector == PortfolioSector.SIN_CLASIFICAR
        ),
        None,
    )
    if unclassified is not None:
        notes.append(
            f"{unclassified.ticker_count} de {total_positions} activos no tienen sector "
            "determinado, así que su aporte a la concentración no se pudo evaluar."
        )

    if level == RiskLevel.BAJA:
        notes.append(
            f"Ningún sector supera el 35% y el reparto entre {distinct} sectores es parejo."
        )

    headline = f"{top.weight_pct:.0f}% concentrado en {top.label} — {_RISK_HEADLINE_WORDS[level]}"

    return ConcentrationRisk(
        level=level,
        headline=headline,
        top_sector=top.sector,
        top_sector_label=top.label,
        top_sector_weight_pct=top.weight_pct,
        distinct_sectors=distinct,
        herfindahl_index=round(herfindahl, 4),
        notes=notes,
    )


def _daily_returns(bars: list[OhlcBar]) -> dict[int, float]:
    """Retornos diarios indexados por el timestamp de la vela, para poder alinear dos series por
    fecha en vez de por posición.

    Alinear por posición sería un bug silencioso: dos tickers pueden tener distinta cantidad de
    velas en el mismo rango (un feriado de su mercado, un listado más reciente, una vela descartada
    por venir incompleta), y emparejar el índice 5 de uno con el índice 5 del otro compararía días
    distintos y devolvería una correlación sin sentido.
    """

    returns: dict[int, float] = {}
    for previous, current in pairwise(bars):
        if previous.close <= 0:
            continue
        returns[current.timestamp_ms] = float(
            (current.close - previous.close) / previous.close
        )
    return returns


def pearson_correlation(
    left: dict[int, float], right: dict[int, float]
) -> tuple[float | None, int]:
    """Correlación de Pearson entre dos series de retornos alineadas por fecha.

    Devuelve `(coeficiente, cantidad_de_observaciones)`. El coeficiente es `None` cuando no se
    puede afirmar: menos de dos días en común, o una de las series constante (varianza 0, que haría
    una división por cero). Ninguno de esos casos es "correlación 0" — es "no medible", y
    devolverlos como 0 haría pasar por medido algo que no lo está.
    """

    shared = sorted(set(left) & set(right))
    count = len(shared)
    if count < 2:
        return None, count

    left_values = [left[key] for key in shared]
    right_values = [right[key] for key in shared]
    left_mean = sum(left_values) / count
    right_mean = sum(right_values) / count

    covariance = sum(
        (a - left_mean) * (b - right_mean)
        for a, b in zip(left_values, right_values, strict=True)
    )
    left_variance = sum((a - left_mean) ** 2 for a in left_values)
    right_variance = sum((b - right_mean) ** 2 for b in right_values)

    if left_variance <= 0 or right_variance <= 0:
        return None, count

    coefficient = covariance / math.sqrt(left_variance * right_variance)
    # El redondeo puede empujar un 1.0000000000000002 (error de punto flotante) fuera del rango que
    # el schema acepta; se acota antes de devolverlo.
    return max(-1.0, min(1.0, round(coefficient, 4))), count


class PortfolioAuditService:
    """Todos los clientes son opcionales y cada ausencia degrada solo su bloque: sin FMP no hay
    sectores (todo cae en `SIN_CLASIFICAR`), sin Polygon las correlaciones caen a la heurística por
    sector, y sin Gemini no hay narrativa. La distribución y la concentración se calculan siempre,
    porque solo dependen de la watchlist del usuario.
    """

    def __init__(
        self,
        session_factory: async_sessionmaker[AsyncSession],
        *,
        catalog_service: TickerCatalogService | None = None,
        fmp_client: FMPClient | None = None,
        polygon_client: PolygonClient | None = None,
        gemini_client: GeminiClient | None = None,
        cache_ttl_seconds: float = 3600.0,
        correlation_window_days: int = 90,
        correlation_threshold: float = 0.8,
        min_correlation_observations: int = 30,
        max_history_tickers: int = 25,
        system_prompt: str | None = None,
    ) -> None:
        self._session_factory = session_factory
        self._catalog = catalog_service or TickerCatalogService(session_factory)
        self._fmp = fmp_client
        self._polygon = polygon_client
        self._gemini = gemini_client
        self._cache_ttl_seconds = cache_ttl_seconds
        self._correlation_window_days = correlation_window_days
        self._correlation_threshold = correlation_threshold
        self._min_correlation_observations = min_correlation_observations
        self._max_history_tickers = max_history_tickers
        self._system_prompt = system_prompt or _load_system_prompt()

        # La clave incluye la huella de la watchlist, no solo el usuario: si agrega o quita un
        # ticker, la entrada vieja deja de matchear y se recalcula sola. Sin eso, la API tendría
        # que acordarse de purgar la caché en cada POST/DELETE de watchlist — y el día que alguien
        # agregue una tercera forma de modificarla, se olvidaría.
        self._cache: dict[tuple[UUID, str], tuple[float, PortfolioAudit]] = {}
        # Un lock por usuario: dos usuarios auditando sus carteras no se esperan entre sí, pero dos
        # pestañas del mismo usuario comparten una única corrida.
        self._locks: dict[UUID, asyncio.Lock] = {}

    async def get_audit(
        self, user_id: UUID, *, force_refresh: bool = False
    ) -> PortfolioAudit:
        holdings = await self._load_holdings(user_id)
        fingerprint = _fingerprint(holdings)
        cache_key = (user_id, fingerprint)

        if not force_refresh:
            cached = self._fresh_cache(cache_key)
            if cached is not None:
                return cached

        lock = self._locks.setdefault(user_id, asyncio.Lock())
        async with lock:
            if not force_refresh:
                # Re-chequeo adentro del lock: mientras se esperaba, otra corrida pudo haberla
                # completado, y repetir la llamada al modelo sería el gasto que se quiere evitar.
                cached = self._fresh_cache(cache_key)
                if cached is not None:
                    return cached

            audit = await self._build(holdings)
            self._cache[cache_key] = (time.monotonic(), audit)
            return audit

    def _fresh_cache(self, key: tuple[UUID, str]) -> PortfolioAudit | None:
        """`time.monotonic` y no `datetime.now`: la caché mide tiempo transcurrido, y un ajuste de
        reloj del sistema no debería invalidarla ni eternizarla.
        """

        entry = self._cache.get(key)
        if entry is None:
            return None
        cached_at, value = entry
        if time.monotonic() - cached_at > self._cache_ttl_seconds:
            return None
        return value.model_copy(update={"served_from_cache": True})

    async def _load_holdings(self, user_id: UUID) -> list[tuple[str, AssetType]]:
        async with self._session_factory() as session:
            rows = (
                await session.execute(
                    select(WatchlistItem.ticker, WatchlistItem.asset_type)
                    .where(WatchlistItem.user_id == user_id)
                    .order_by(WatchlistItem.ticker)
                )
            ).all()
        return [(ticker, asset_type) for ticker, asset_type in rows]

    async def _build(self, holdings: list[tuple[str, AssetType]]) -> PortfolioAudit:
        generated_at = datetime.now(timezone.utc)

        if not holdings:
            return PortfolioAudit(
                generated_at=generated_at,
                position_count=0,
                availability=DataAvailability.UNAVAILABLE,
                sector_data_available=False,
                degradation_reason=_REASON_EMPTY_WATCHLIST,
            )

        sectors, sector_reason = await self._resolve_sectors(holdings)
        allocations = build_sector_allocation(sectors)
        concentration = build_concentration_risk(allocations)

        warnings, measured = await self._correlation_warnings(sectors)
        suggestions = _build_suggestions(allocations, concentration)

        summary, ai_reason = await self._narrate(
            allocations, concentration, warnings, suggestions, len(holdings)
        )

        classified = sum(
            1 for sector in sectors.values() if sector != PortfolioSector.SIN_CLASIFICAR
        )
        reasons = [
            reason
            for reason in (
                sector_reason,
                ai_reason,
                _REASON_SINGLE_POSITION if len(holdings) == 1 else None,
            )
            if reason is not None
        ]

        # PARTIAL y no AVAILABLE mientras falte cualquier bloque: el cliente pinta un aviso arriba
        # con este flag, y decir AVAILABLE con la narrativa vacía lo dejaría sin saber que falta
        # algo. Solo la ausencia total de sectores llega a UNAVAILABLE — sin sectores no hay
        # auditoría, solo una lista de tickers.
        if classified == 0:
            availability = DataAvailability.UNAVAILABLE
        elif reasons:
            availability = DataAvailability.PARTIAL
        else:
            availability = DataAvailability.AVAILABLE

        return PortfolioAudit(
            generated_at=generated_at,
            position_count=len(holdings),
            availability=availability,
            sector_allocation=allocations,
            sector_data_available=classified > 0,
            risk_concentration=concentration,
            correlation_warnings=warnings,
            correlation_measured=measured,
            diversification_suggestions=suggestions,
            ai_summary=summary,
            ai_summary_available=summary is not None,
            degradation_reason=" ".join(reasons) if reasons else None,
        )

    async def _resolve_sectors(
        self, holdings: list[tuple[str, AssetType]]
    ) -> tuple[dict[str, PortfolioSector], str | None]:
        """Sector de cada activo, resuelto en tres pasos: cripto por tipo de activo, catálogo local,
        y FMP para el resto (persistiendo lo que resuelva).

        Devuelve también el motivo de degradación si algún símbolo quedó sin clasificar.
        """

        sectors: dict[str, PortfolioSector] = {}
        pending: list[str] = []

        for ticker, asset_type in holdings:
            if asset_type == AssetType.CRYPTO:
                # No se le pregunta a FMP: una cripto no tiene sector empresario, y el proveedor de
                # fundamentales de acciones tampoco lo sabría.
                sectors[ticker] = PortfolioSector.CRIPTO
            else:
                pending.append(ticker)

        if pending:
            from_catalog = await self._catalog.find_sectors(pending)
            for ticker in list(pending):
                raw = from_catalog.get(ticker)
                if raw is not None:
                    sectors[ticker] = normalize_sector(raw)
                    pending.remove(ticker)

        if pending and self._fmp is not None:
            resolved = await self._fetch_sectors_from_provider(pending)
            for ticker, raw in resolved.items():
                sectors[ticker] = normalize_sector(raw)
                pending.remove(ticker)
            if resolved:
                # Write-through al catálogo: el sector de un símbolo es el mismo para todos los
                # usuarios y no cambia de un mes al otro.
                await self._catalog.store_sectors(resolved)

        for ticker in pending:
            sectors[ticker] = PortfolioSector.SIN_CLASIFICAR

        if not pending:
            return sectors, None
        if self._fmp is None and all(
            sector == PortfolioSector.SIN_CLASIFICAR
            for ticker, sector in sectors.items()
            if ticker in pending
        ):
            return sectors, _REASON_NO_SECTOR_SOURCE
        return sectors, _REASON_PARTIAL_SECTORS

    async def _fetch_sectors_from_provider(self, tickers: list[str]) -> dict[str, str]:
        """Consulta `/profile` de cada símbolo en paralelo. Un símbolo que falle o venga sin sector
        no entra en el dict: queda pendiente y se declara `SIN_CLASIFICAR`, en vez de contaminar el
        catálogo con un sector adivinado.
        """

        fmp = self._fmp
        if fmp is None:
            return {}

        results = await asyncio.gather(
            *(fmp.get_company_profile(ticker) for ticker in tickers),
            return_exceptions=True,
        )

        resolved: dict[str, str] = {}
        for ticker, result in zip(tickers, results, strict=True):
            if isinstance(result, BaseException):
                logger.warning(
                    "portfolio_audit_profile_failed",
                    extra={"ticker": ticker, "error": str(result)},
                )
                continue
            if result is None or result.sector is None:
                continue
            resolved[ticker] = result.sector
        return resolved

    async def _correlation_warnings(
        self, sectors: dict[str, PortfolioSector]
    ) -> tuple[list[CorrelationWarning], bool]:
        """Advertencias de correlación: medidas contra precios reales donde se puede, heurísticas
        por sector donde no.

        Devuelve `(advertencias, se_midió_al_menos_un_par)`. El segundo valor cuenta PARES
        efectivamente medidos, no series descargadas: con histórico de un solo símbolo, o con dos
        series que casi no se solapan, no hay ninguna correlación medida — y declarar que sí haría
        que la ausencia de advertencias se leyera como "los medimos y no correlacionan" cuando en
        realidad es "no los pudimos medir".
        """

        tickers = sorted(sectors)
        if len(tickers) < 2:
            return [], False

        returns = await self._fetch_returns(tickers)

        measured: list[CorrelationWarning] = []
        unmeasured_pairs: list[tuple[str, str]] = []
        measured_pairs = 0

        for index, left in enumerate(tickers):
            for right in tickers[index + 1 :]:
                left_returns = returns.get(left)
                right_returns = returns.get(right)
                if left_returns is None or right_returns is None:
                    unmeasured_pairs.append((left, right))
                    continue

                coefficient, observations = pearson_correlation(
                    left_returns, right_returns
                )
                if (
                    coefficient is None
                    or observations < self._min_correlation_observations
                ):
                    # Pocos días en común no es "no correlacionan": es "no se puede afirmar". El par
                    # pasa a la heurística por sector, que al menos declara de dónde sale.
                    unmeasured_pairs.append((left, right))
                    continue

                measured_pairs += 1
                if abs(coefficient) < self._correlation_threshold:
                    continue

                measured.append(
                    CorrelationWarning(
                        tickers=[left, right],
                        basis=CorrelationBasis.PRICE_HISTORY,
                        coefficient=coefficient,
                        observations=observations,
                        message=(
                            f"{left} y {right} se movieron casi igual en los últimos "
                            f"{observations} días de rueda (correlación {coefficient:+.2f}): "
                            "sumarlos aporta menos diversificación de la que aparenta."
                        ),
                    )
                )

        heuristic = _sector_heuristic_warnings(unmeasured_pairs, sectors)

        # Las medidas primero y ordenadas por fuerza: si hay que recortar, se recorta lo más débil y
        # lo menos fundado, no lo que quedó último alfabéticamente.
        measured.sort(key=lambda warning: -abs(warning.coefficient or 0.0))
        combined = (measured + heuristic)[:_MAX_CORRELATION_WARNINGS]
        return combined, measured_pairs > 0

    async def _fetch_returns(self, tickers: list[str]) -> dict[str, dict[int, float]]:
        """Retornos diarios de cada símbolo. Sin Polygon devuelve vacío y todas las advertencias
        caen a la heurística por sector.

        Se acota a `max_history_tickers` símbolos: la auditoría corre en el camino de un request
        HTTP, y una watchlist de 200 activos disparando 200 llamadas al proveedor convertiría un
        endpoint de lectura en una tormenta de tráfico. Los símbolos que quedan afuera no pierden
        cobertura, la pierden de calidad: pasan a la heurística por sector, declarada como tal.
        """

        polygon = self._polygon
        if polygon is None:
            return {}

        # La fecha se toma en UTC, igual que en `/market/history`: con la fecha local de un proceso
        # al este de Greenwich se pediría un rango que termina "mañana" para el proveedor.
        end = datetime.now(timezone.utc).date()
        start = end - timedelta(days=self._correlation_window_days)
        selected = tickers[: self._max_history_tickers]

        results = await asyncio.gather(
            *(
                polygon.get_daily_ohlc(ticker, start=start, end=end)
                for ticker in selected
            ),
            return_exceptions=True,
        )

        returns: dict[str, dict[int, float]] = {}
        for ticker, result in zip(selected, results, strict=True):
            if isinstance(result, BaseException):
                logger.warning(
                    "portfolio_audit_history_failed",
                    extra={"ticker": ticker, "error": str(result)},
                )
                continue
            series = _daily_returns(result)
            if series:
                returns[ticker] = series
        return returns

    async def _narrate(
        self,
        allocations: list[SectorAllocation],
        concentration: ConcentrationRisk | None,
        warnings: list[CorrelationWarning],
        suggestions: list[DiversificationSuggestion],
        position_count: int,
    ) -> tuple[str | None, str | None]:
        """Devuelve `(narrativa, motivo_de_degradación)`. Nunca lanza: un fallo del modelo no debe
        tumbar una auditoría cuyos cálculos ya están listos.
        """

        if (gemini := self._gemini) is None:
            return None, _REASON_NO_GEMINI

        result = await gemini.generate_structured_json(
            system_instruction=self._system_prompt,
            user_content=_build_audit_context(
                allocations, concentration, warnings, suggestions, position_count
            ),
            response_schema=_RESPONSE_SCHEMA,
        )

        if result.status != DataStatus.OK or result.raw_json_text is None:
            logger.warning("portfolio_audit_gemini_call_failed")
            return None, _REASON_GEMINI_FAILED

        try:
            parsed = json.loads(result.raw_json_text)
            # strict=False solo en esta frontera JSON, mismo caso que el resto de los servicios que
            # consumen al modelo: JSON no tiene tipo nativo para Decimal ni Enum.
            output = _LLMAuditOutput.model_validate(parsed, strict=False)
        except (json.JSONDecodeError, ValidationError) as exc:
            logger.warning("portfolio_audit_output_invalid", extra={"error": str(exc)})
            return None, _REASON_GEMINI_INVALID

        summary = output.summary.strip()
        if not summary:
            return None, _REASON_GEMINI_INVALID
        return summary, None


def _fingerprint(holdings: list[tuple[str, AssetType]]) -> str:
    """Huella de la composición de la watchlist, para la clave de caché.

    Incluye el tipo de activo además del símbolo porque la clasificación depende de él: el mismo
    símbolo marcado como CRYPTO o como STOCK cae en sectores distintos.
    """

    joined = "|".join(f"{ticker}:{asset_type.value}" for ticker, asset_type in holdings)
    return hashlib.sha256(joined.encode("utf-8")).hexdigest()[:16]


def _sector_heuristic_warnings(
    pairs: list[tuple[str, str]], sectors: dict[str, PortfolioSector]
) -> list[CorrelationWarning]:
    """Advertencia por sector compartido para los pares que no se pudieron medir.

    Marcada `basis=SECTOR` y sin coeficiente: es una inferencia sobre a qué se dedican dos empresas,
    no una medición de cómo se movieron. Se emite igual porque callarse sería peor —dos bancos en la
    misma cartera comparten riesgo aunque falte el histórico— pero el usuario tiene que poder
    distinguirla de una correlación medida.

    `SIN_CLASIFICAR` queda afuera: dos símbolos cuyo sector no se conoce no comparten un sector, solo
    comparten que no se sabe cuál es.
    """

    grouped: dict[PortfolioSector, list[tuple[str, str]]] = {}
    for left, right in pairs:
        sector = sectors.get(left)
        if sector is None or sector != sectors.get(right):
            continue
        if sector == PortfolioSector.SIN_CLASIFICAR:
            continue
        grouped.setdefault(sector, []).append((left, right))

    warnings: list[CorrelationWarning] = []
    for sector, sector_pairs in sorted(grouped.items(), key=lambda item: item[0].value):
        involved = sorted({ticker for pair in sector_pairs for ticker in pair})
        label = sector_label(sector)
        warnings.append(
            CorrelationWarning(
                tickers=involved,
                basis=CorrelationBasis.SECTOR,
                coefficient=None,
                observations=None,
                message=(
                    f"{', '.join(involved)} comparten sector ({label}), así que tienden a "
                    "reaccionar juntos a lo que afecte al sector. No se pudo medir la correlación "
                    "real de precios para confirmarlo."
                ),
            )
        )
    return warnings


def _build_suggestions(
    allocations: list[SectorAllocation], concentration: ConcentrationRisk | None
) -> list[DiversificationSuggestion]:
    """Hasta tres sectores ausentes o subrepresentados, de la tabla de complementos.

    Se emiten también cuando la concentración es baja, con otra redacción: una cartera bien
    repartida entre tres sectores sigue teniendo huecos, y el bloque tiene que decir algo en vez de
    quedar vacío (que el cliente leería como un error).
    """

    if not allocations:
        return []

    present: dict[PortfolioSector, float] = {
        allocation.sector: allocation.weight_pct
        for allocation in allocations
        if allocation.sector != PortfolioSector.SIN_CLASIFICAR
    }
    level = concentration.level if concentration is not None else RiskLevel.BAJA
    top_label = concentration.top_sector_label if concentration is not None else "—"

    suggestions: list[DiversificationSuggestion] = []
    seen: set[PortfolioSector] = set()
    for sector in _COMPLEMENT_SECTORS:
        if len(suggestions) >= _SUGGESTIONS_TARGET:
            break
        if sector in seen:
            continue
        weight = present.get(sector)
        if weight is not None and weight >= _UNDERWEIGHT_PCT:
            continue
        seen.add(sector)

        label = sector_label(sector)
        if weight is None:
            presence = f"No seguís ningún activo de {label}."
        else:
            presence = f"{label} pesa apenas {weight:.0f}% de tu lista."

        if level in (RiskLevel.ALTA, RiskLevel.CRITICA):
            rationale = (
                f"{presence} Es un sector que suele moverse por motivos distintos a "
                f"{top_label}, donde hoy está la mayor parte de tu cartera."
            )
        else:
            rationale = (
                f"{presence} Sumarlo ampliaría la cantidad de sectores de tu lista, que ya está "
                "razonablemente repartida."
            )

        suggestions.append(
            DiversificationSuggestion(sector=sector, label=label, rationale=rationale)
        )

    return suggestions


def _build_audit_context(
    allocations: list[SectorAllocation],
    concentration: ConcentrationRisk | None,
    warnings: list[CorrelationWarning],
    suggestions: list[DiversificationSuggestion],
    position_count: int,
) -> str:
    """Arma el `<portfolio_audit>` que el prompt exige como única fuente.

    Se le pasan los resultados YA calculados, incluida la advertencia de que los pesos son
    equiponderados: si el bloque no lo dijera, el modelo escribiría "el 40% de tu capital", que es
    una afirmación que estos datos no sostienen.
    """

    allocation_lines = (
        "\n".join(
            f"  - {allocation.label}: {allocation.weight_pct:.1f}% "
            f"({', '.join(allocation.tickers)})"
            for allocation in allocations
        )
        or "  (sin activos)"
    )

    if concentration is None:
        concentration_block = "  (no evaluable)"
    else:
        notes = "\n".join(f"    · {note}" for note in concentration.notes)
        concentration_block = (
            f"  Nivel: {concentration.level.value}\n"
            f"  Titular: {concentration.headline}\n"
            f"  Sectores distintos: {concentration.distinct_sectors}\n"
            f"  Índice de Herfindahl (0-1): {concentration.herfindahl_index:.3f}"
            + (f"\n  Señales:\n{notes}" if notes else "")
        )

    warning_lines = (
        "\n".join(
            f"  - [{warning.basis.value}] {', '.join(warning.tickers)}: {warning.message}"
            for warning in warnings
        )
        or "  (ninguna)"
    )

    suggestion_lines = (
        "\n".join(
            f"  - {suggestion.label}: {suggestion.rationale}"
            for suggestion in suggestions
        )
        or "  (ninguna)"
    )

    return (
        "<portfolio_audit>\n"
        f"Cantidad de activos seguidos: {position_count}\n"
        "Base de ponderación: EQUIPONDERADA POR CANTIDAD DE ACTIVOS. La watchlist no guarda "
        "cantidades ni precio de compra, así que estos porcentajes son cuántos activos de la lista "
        "pertenecen a cada sector, NO cuánto dinero hay invertido en cada uno.\n"
        "Distribución por sector:\n"
        f"{allocation_lines}\n"
        "Concentración de riesgo (calculada por el backend):\n"
        f"{concentration_block}\n"
        "Advertencias de correlación:\n"
        f"{warning_lines}\n"
        "Sectores sugeridos para balancear:\n"
        f"{suggestion_lines}\n"
        "</portfolio_audit>"
    )
