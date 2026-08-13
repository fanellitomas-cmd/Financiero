"""Lo que comparten la Auditoría de Portafolio y el Constructor de Portafolios.

Vive acá porque las dos features contestan preguntas distintas sobre la misma cartera y **no pueden
contradecirse**: si cada una tuviera su propia tabla de umbrales, la misma concentración podría dar
"riesgo alto" en una pantalla y "moderado" en la otra, y quien las viera juntas no tendría forma de
saber cuál creer. Un solo lugar, un solo veredicto.

Dos bloques:

  1. **Resolución de sector** (`resolve_sectors`) — cripto por tipo de activo, catálogo local, y FMP
     `/profile` para el resto con write-through al catálogo. Lo que no se resuelve cae en
     `SIN_CLASIFICAR`, nunca en un sector plausible.
  2. **Escala de concentración** (`level_from_*`, `herfindahl_index`, `worst_risk_level`) — umbrales
     explícitos en código. La misma cartera tiene que dar siempre el mismo nivel.
"""

from __future__ import annotations

import asyncio
import logging

from app.models.enums import AssetType
from app.schemas.portfolio_audit import PortfolioSector, RiskLevel
from app.services.ticker_catalog_service import TickerCatalogService
from src.ingestion.fmp_client import FMPClient

logger = logging.getLogger(__name__)

REASON_NO_SECTOR_SOURCE = (
    "La clasificación por sector no está configurada en este entorno (falta FMP_API_KEY en .env) "
    "y el catálogo local todavía no tiene el sector de estos símbolos."
)
REASON_PARTIAL_SECTORS = (
    "No se pudo determinar el sector de todos los activos; los que faltan figuran como "
    "'Sin clasificar' y se cuentan aparte en la concentración."
)

# Vocabulario de FMP -> vocabulario del producto. Las claves se comparan en minúsculas y sin
# espacios de sobra, así que `Financial Services` y `financial services` caen en el mismo lugar.
#
# Un sector que no esté en esta tabla NO se descarta ni se adivina: cae en `SIN_CLASIFICAR` y queda
# visible en la respuesta, que es la señal de que hay que agregarlo acá.
SECTOR_TRANSLATIONS: dict[str, PortfolioSector] = {
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


def provider_sector_keys(sector: PortfolioSector) -> list[str]:
    """Camino inverso de `normalize_sector`: qué nombres del proveedor caen en este sector del
    producto, en minúsculas.

    Lo usa la búsqueda en lenguaje natural para filtrar el catálogo, que guarda el sector CRUDO
    (`Technology`), a partir de un criterio del producto (`TECNOLOGIA`). Se deriva de la misma tabla
    que la traducción de ida, así que agregar un alias nuevo sirve para las dos direcciones sin poder
    desincronizarlas.

    Devuelve vacío para `CRIPTO` y `SIN_CLASIFICAR`: ninguno de los dos existe en el vocabulario del
    proveedor de acciones — el primero se asigna por tipo de activo y el segundo es la ausencia de
    sector.
    """

    return [raw for raw, mapped in SECTOR_TRANSLATIONS.items() if mapped is sector]


def normalize_sector(raw: str | None) -> PortfolioSector:
    """Sector crudo del proveedor -> sector del producto. `None` y lo desconocido caen en
    `SIN_CLASIFICAR`, nunca en un sector plausible: adivinarle el sector a un símbolo desconocido
    contaminaría el cálculo de concentración con una afirmación inventada.
    """

    if raw is None:
        return PortfolioSector.SIN_CLASIFICAR
    return SECTOR_TRANSLATIONS.get(raw.strip().lower(), PortfolioSector.SIN_CLASIFICAR)


async def _fetch_sectors_from_provider(
    tickers: list[str], *, fmp: FMPClient | None
) -> dict[str, str]:
    """Consulta `/profile` de cada símbolo en paralelo. Un símbolo que falle o venga sin sector no
    entra en el dict: queda pendiente y se declara `SIN_CLASIFICAR`, en vez de contaminar el catálogo
    con un sector adivinado.
    """

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
                "portfolio_profile_failed",
                extra={"ticker": ticker, "error": str(result)},
            )
            continue
        if result is None or result.sector is None:
            continue
        resolved[ticker] = result.sector
    return resolved


async def resolve_sectors(
    holdings: list[tuple[str, AssetType]],
    *,
    catalog: TickerCatalogService,
    fmp: FMPClient | None,
) -> tuple[dict[str, PortfolioSector], str | None]:
    """Sector de cada activo, resuelto en tres pasos: cripto por tipo de activo, catálogo local, y
    FMP para el resto (persistiendo lo que resuelva).

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
        from_catalog = await catalog.find_sectors(pending)
        for ticker in list(pending):
            raw = from_catalog.get(ticker)
            if raw is not None:
                sectors[ticker] = normalize_sector(raw)
                pending.remove(ticker)

    if pending and fmp is not None:
        resolved = await _fetch_sectors_from_provider(pending, fmp=fmp)
        for ticker, raw in resolved.items():
            sectors[ticker] = normalize_sector(raw)
            pending.remove(ticker)
        if resolved:
            # Write-through al catálogo: el sector de un símbolo es el mismo para todos los usuarios
            # y no cambia de un mes al otro.
            await catalog.store_sectors(resolved)

    for ticker in pending:
        sectors[ticker] = PortfolioSector.SIN_CLASIFICAR

    if not pending:
        return sectors, None
    if fmp is None and all(
        sector == PortfolioSector.SIN_CLASIFICAR
        for ticker, sector in sectors.items()
        if ticker in pending
    ):
        return sectors, REASON_NO_SECTOR_SOURCE
    return sectors, REASON_PARTIAL_SECTORS


# --- Escala de concentración -----------------------------------------------------------------


def level_from_top_weight(top_weight_pct: float) -> RiskLevel:
    if top_weight_pct >= 70:
        return RiskLevel.CRITICA
    if top_weight_pct >= 50:
        return RiskLevel.ALTA
    if top_weight_pct >= 35:
        return RiskLevel.MODERADA
    return RiskLevel.BAJA


def level_from_herfindahl(index: float) -> RiskLevel:
    if index >= 0.60:
        return RiskLevel.CRITICA
    if index >= 0.40:
        return RiskLevel.ALTA
    if index >= 0.25:
        return RiskLevel.MODERADA
    return RiskLevel.BAJA


RISK_ORDER: dict[RiskLevel, int] = {
    RiskLevel.BAJA: 0,
    RiskLevel.MODERADA: 1,
    RiskLevel.ALTA: 2,
    RiskLevel.CRITICA: 3,
}

RISK_HEADLINE_WORDS: dict[RiskLevel, str] = {
    RiskLevel.BAJA: "riesgo bajo",
    RiskLevel.MODERADA: "riesgo moderado",
    RiskLevel.ALTA: "riesgo alto",
    RiskLevel.CRITICA: "riesgo muy alto",
}


def herfindahl_index(weights_pct: list[float]) -> float:
    """Suma de los cuadrados de los pesos, con los pesos en 0..1.

    Recibe porcentajes (0..100) porque es como viajan en los dos módulos, y divide acá: pasarle
    fracciones por error daría un índice 10.000 veces más chico y un veredicto siempre "BAJA".
    """

    return sum((weight / 100) ** 2 for weight in weights_pct)


def worst_risk_level(*levels: RiskLevel) -> RiskLevel:
    """El peor de varios niveles.

    Existe porque medir la concentración con UNA sola medida tiene punto ciego en las dos
    direcciones: una cartera 34/33/33 tiene un dominante inofensivo y es igual una cartera de tres
    sectores, y una cartera con 12 sectores donde uno pesa 40% no está mal repartida. Tomar el peor
    de los dos evita firmar "riesgo bajo" en los dos casos.
    """

    return max(levels, key=lambda value: RISK_ORDER[value])
