"""Servicio de `POST /api/v1/portfolio-builder/simulate` — el Constructor de Portafolios.

Reparte un presupuesto entre varias posiciones y devuelve el resultado completo: unidades, montos,
efectivo sobrante, distribución por sector, concentración y retorno histórico ponderado.

**Todo el reparto es aritmética en código.** No hay modelo en ningún paso, y no lo hay a propósito:
"cuántas unidades entran con este presupuesto" tiene una única respuesta correcta, y pedírsela a un
modelo introduciría variación en una cuenta que no la admite.

El orden del cálculo importa y es este:

  1. **Precios.** El personalizado gana sobre el de mercado; sin ninguno de los dos, la posición
     queda en 0 unidades con su motivo y no se descarta de la respuesta.
  2. **Unidades enteras**, por piso. La fracción que no llega se convierte en efectivo sobrante.
  3. **Sectores**, por el mismo camino de tres pasos que la Auditoría (`portfolio_common`).
  4. **Concentración**, sobre pesos de DINERO, con los umbrales compartidos.
  5. **Retorno a 1 año**, contra precios reales y declarando qué porción del capital se pudo medir.

Nada de esto devuelve 503. Una cartera donde todas las posiciones traen `custom_price` se calcula
entera sin proveedor: es el caso de uso central de la feature, y exigir credenciales para atenderlo
dejaría inalcanzable justamente lo que la distingue.
"""

from __future__ import annotations

import asyncio
import logging
import math
from datetime import date, datetime, timedelta, timezone

from typing import NamedTuple

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.schemas.intelligence import DataAvailability
from app.schemas.market import TickerHistory, TickerQuote
from app.schemas.portfolio_audit import PortfolioSector, sector_label
from app.schemas.portfolio_builder import (
    MIN_USABLE_PRICE,
    AllocationType,
    PortfolioAllocationItem,
    PortfolioItemInput,
    PortfolioSimulationRequest,
    PortfolioSimulationResult,
    PriceSource,
    SectorAmountAllocation,
    UnitRounding,
)
from app.services.market_data_service import MarketDataService
from app.services.portfolio_common import (
    herfindahl_index,
    level_from_herfindahl,
    level_from_top_weight,
    resolve_sectors,
    worst_risk_level,
)
from app.services.ticker_catalog_service import TickerCatalogService
from src.ingestion.fmp_client import FMPClient

logger = logging.getLogger(__name__)

# Ventana para buscar el precio de hace un año. Se toma la vela más cercana al objetivo DENTRO de la
# ventana: "hace exactamente un año" cae en sábado, domingo o feriado la mayoría de las veces, y
# pedir una sola fecha devolvería vacío sin que falte ningún dato.
_YEAR_LOOKBACK_DAYS = 365
_YEAR_WINDOW_DAYS = 12

_REASON_NO_MARKET_SOURCE = (
    "Los precios en vivo no están configurados en este entorno (falta POLYGON_API_KEY en .env), así "
    "que solo se pudieron calcular las posiciones con precio esperado."
)
_REASON_SOME_PRICES_MISSING = (
    "No se pudo obtener el precio de todos los símbolos; los que faltan figuran con 0 unidades y su "
    "motivo, y no entran en los porcentajes."
)
_NOTE_NO_PRICE = (
    "Sin precio de mercado disponible y sin precio esperado ingresado: no hay con qué calcular "
    "unidades."
)
_NOTE_PRICE_TOO_LOW = (
    f"El precio efectivo es menor a US$ {MIN_USABLE_PRICE:.2f}: por debajo de un centavo la cantidad "
    "de unidades deja de representar una operación real."
)
_NOTE_UNITS_BELOW_ONE = (
    "El monto asignado no alcanza para una unidad entera a este precio, así que queda entero como "
    "efectivo sobrante."
)
_NOTE_NO_HISTORY = "Sin histórico de precios para medir el retorno del último año."

_NOTE_CUSTOM_PRICE_WEIGHTS = (
    "El retorno del último año de cada posición se mide contra precios REALES de mercado; el precio "
    "esperado solo cambia el peso con el que ese retorno entra al total."
)
_NOTE_WHOLE_UNITS = (
    "Las unidades se redondean hacia abajo a enteros y la fracción que no llega queda como efectivo "
    "sobrante."
)
_NOTE_RETURN_IS_HISTORICAL = (
    "El retorno a 1 año es lo que pasó, no una proyección: mide el precio de hace un año contra el "
    "actual y no dice nada sobre lo que viene."
)


class _Resolved(NamedTuple):
    """Una posición ya resuelta en precio y unidades, antes de conocer el total asignado.

    Existe porque `percentage_of_total` necesita DOS pasadas: el total sobre el que se mide no se
    conoce hasta haber redondeado todas las unidades.
    """

    item: PortfolioItemInput
    market_price: float | None
    effective_price: float | None
    units: int
    invested: float
    note: str | None


def _percentage(part: float, whole: float) -> float:
    """Porcentaje con el cero protegido. Un total de 0 no da 0% ni 100%: no da nada."""

    if whole <= 0:
        return 0.0
    return round(part / whole * 100, 2)


def target_amount(item: PortfolioItemInput, *, budget: float, price: float) -> float:
    """El capital que el usuario pidió poner en esta posición, antes de redondear unidades.

    Las tres formas terminan en dólares porque es la única unidad en la que se pueden sumar entre
    sí: un pedido de "100 unidades" y otro de "20% del presupuesto" no se comparan hasta que los dos
    están en la misma moneda.
    """

    if item.allocation_type == AllocationType.UNITS:
        return item.allocation_value * price
    if item.allocation_type == AllocationType.AMOUNT_USD:
        return item.allocation_value
    return budget * item.allocation_value / 100


def units_for(amount: float, price: float) -> int:
    """Unidades enteras que caben en `amount` a `price`.

    `math.floor` y no `round`: redondear para arriba compraría más de lo que el presupuesto permite y
    haría que la suma de las posiciones supere el total sin que el usuario haya pedido nada de eso.
    """

    if price < MIN_USABLE_PRICE:
        return 0
    return math.floor(amount / price)


def build_sector_amounts(
    items: list[PortfolioAllocationItem],
    sectors: dict[str, PortfolioSector],
) -> list[SectorAmountAllocation]:
    """Distribución por sector ponderada por capital invertido, de mayor a menor peso.

    Las posiciones con 0 invertido no entran: un símbolo que no se pudo cotizar no aporta
    concentración, y contarlo con peso 0 agregaría un sector a la torta que no representa nada.

    El empate se rompe por nombre de sector para que dos corridas de la misma cartera devuelvan el
    mismo orden — un orden que baila haría que la UI reordene la torta sin que nada haya cambiado.
    """

    invested = [item for item in items if item.invested_amount > 0]
    total = sum(item.invested_amount for item in invested)
    if total <= 0:
        return []

    grouped: dict[PortfolioSector, list[PortfolioAllocationItem]] = {}
    for item in sorted(invested, key=lambda value: value.ticker):
        sector = sectors.get(item.ticker, PortfolioSector.SIN_CLASIFICAR)
        grouped.setdefault(sector, []).append(item)

    allocations = [
        SectorAmountAllocation(
            sector=sector,
            label=sector_label(sector),
            amount=round(sum(item.invested_amount for item in group), 2),
            percentage_of_total=_percentage(
                sum(item.invested_amount for item in group), total
            ),
            ticker_count=len(group),
            tickers=[item.ticker for item in group],
        )
        for sector, group in grouped.items()
    ]
    allocations.sort(key=lambda value: (-value.percentage_of_total, value.sector.value))
    return allocations


def weighted_return_1y(
    items: list[PortfolioAllocationItem],
) -> tuple[float | None, float]:
    """Retorno ponderado a 1 año y qué porción del capital se pudo medir.

    Se pondera sobre el capital MEDIBLE, no sobre el total: si dos de cinco posiciones no tienen
    histórico, promediar sobre el total equivaldría a asumir que esas dos rindieron 0%, que es una
    afirmación que nadie hizo. Devuelve `(None, 0.0)` cuando no se pudo medir nada, para que el campo
    viaje en `null` en vez de un cero que se leería como "no se movió".
    """

    invested_total = sum(item.invested_amount for item in items)
    measurable = [
        item
        for item in items
        if item.return_1y_pct is not None and item.invested_amount > 0
    ]
    measured_amount = sum(item.invested_amount for item in measurable)

    coverage = _percentage(measured_amount, invested_total)
    if not measurable or measured_amount <= 0:
        return None, coverage

    weighted = sum(
        (item.return_1y_pct or 0.0) * item.invested_amount for item in measurable
    )
    return round(weighted / measured_amount, 2), coverage


def build_risk(
    allocations: list[SectorAmountAllocation],
) -> tuple[PortfolioSector | None, float | None, float | None, list[str]]:
    """Veredicto de concentración sobre pesos de dinero.

    Usa las mismas dos medidas y los mismos umbrales que la Auditoría (`portfolio_common`), tomando
    la peor: el peso del sector dominante y el índice de Herfindahl. Devuelve
    `(sector_top, peso_top, herfindahl, notas)` — el nivel lo arma el llamador con `worst_risk_level`
    para no devolver cinco cosas.
    """

    if not allocations:
        return None, None, None, []

    top = allocations[0]
    index = herfindahl_index(
        [allocation.percentage_of_total for allocation in allocations]
    )

    notes: list[str] = []
    distinct = len(allocations)
    positions = sum(allocation.ticker_count for allocation in allocations)

    if distinct == 1:
        notes.append(
            f"Las {positions} posiciones con capital asignado caen en el mismo sector "
            f"({top.label}): no hay diversificación sectorial."
        )
    elif distinct == 2:
        notes.append(
            "Todo el capital se reparte entre dos sectores; un shock que afecte a uno mueve "
            "aproximadamente la mitad de la cartera."
        )

    if positions < 3:
        # Se avisa en vez de bajarle el nivel: 100% en un sector con dos posiciones ES concentración
        # máxima, pero el veredicto dice más sobre el tamaño de la cartera que sobre el criterio de
        # quien la armó, y conviene decirlo.
        notes.append(
            "La cartera todavía es corta, así que el nivel refleja sobre todo su tamaño: con pocas "
            "posiciones cualquier reparto aparece concentrado."
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
            f"{unclassified.percentage_of_total:.0f}% del capital está en símbolos cuyo sector no se "
            "pudo determinar, así que su aporte a la concentración no se pudo evaluar."
        )

    return top.sector, top.percentage_of_total, round(index, 4), notes


class PortfolioBuilderService:
    """Compone la simulación. Sin estado propio: cada request se calcula de cero.

    No hay caché a propósito, a diferencia de la Auditoría: la clave tendría que incluir el
    presupuesto, cada ticker, cada tipo de asignación, cada valor y cada precio personalizado — o sea
    casi el request entero — y una caché que casi nunca acierta es un costo sin beneficio. Las
    cotizaciones y los históricos que consume sí se cachean, pero río arriba.
    """

    def __init__(
        self,
        session_factory: async_sessionmaker[AsyncSession],
        *,
        catalog_service: TickerCatalogService | None = None,
        market_data_service: MarketDataService | None = None,
        fmp_client: FMPClient | None = None,
    ) -> None:
        self._catalog = catalog_service or TickerCatalogService(session_factory)
        self._market = market_data_service
        self._fmp = fmp_client

    async def simulate(
        self, request: PortfolioSimulationRequest, *, today: date | None = None
    ) -> PortfolioSimulationResult:
        now = datetime.now(timezone.utc)
        reference_day = today or now.date()

        # Se deduplica por símbolo conservando el ORDEN de entrada: dos veces el mismo ticker en la
        # misma cartera es un error de armado, y sumarlo dos veces produciría una concentración que el
        # usuario no pidió. Gana la primera aparición, que es la que el usuario escribió primero.
        seen: set[str] = set()
        inputs: list[PortfolioItemInput] = []
        for item in request.items:
            symbol = item.normalized_ticker
            if symbol in seen:
                continue
            seen.add(symbol)
            inputs.append(item)

        quotes = await self._quotes(inputs)
        names = await self._names(inputs)
        sectors, sector_reason = await resolve_sectors(
            [(item.normalized_ticker, item.asset_type) for item in inputs],
            catalog=self._catalog,
            fmp=self._fmp,
        )
        returns = await self._returns_1y(inputs, reference_day=reference_day)

        items = self._allocate(
            inputs,
            budget=request.total_budget,
            quotes=quotes,
            names=names,
            sectors=sectors,
            returns=returns,
        )

        allocated = round(sum(item.invested_amount for item in items), 2)
        over_budget = (
            round(allocated - request.total_budget, 2)
            if allocated > request.total_budget
            else None
        )
        cash = (
            0.0
            if over_budget is not None
            else round(request.total_budget - allocated, 2)
        )

        sector_allocation = build_sector_amounts(items, sectors)
        top_sector, top_weight, index, risk_notes = build_risk(sector_allocation)
        risk_score = (
            worst_risk_level(
                level_from_top_weight(top_weight),
                level_from_herfindahl(index),
            )
            if top_weight is not None and index is not None
            else None
        )

        portfolio_return, coverage = weighted_return_1y(items)

        priced = [item for item in items if item.effective_price is not None]
        availability, reason = self._availability(
            total=len(items), priced=len(priced), sector_reason=sector_reason
        )

        return PortfolioSimulationResult(
            generated_at=now,
            total_budget=request.total_budget,
            allocated_amount=allocated,
            cash_unallocated=cash,
            cash_pct=_percentage(cash, request.total_budget),
            over_budget_amount=over_budget,
            items=items,
            sector_allocation=sector_allocation,
            portfolio_return_1y_pct=portfolio_return,
            return_coverage_pct=coverage,
            risk_score=risk_score,
            herfindahl_index=index,
            top_sector=top_sector,
            top_sector_weight_pct=top_weight,
            risk_notes=risk_notes,
            unit_rounding=UnitRounding.FLOOR_TO_WHOLE_UNITS,
            availability=availability,
            degradation_reason=reason,
            notes=self._notes(items, over_budget=over_budget),
        )

    def _allocate(
        self,
        inputs: list[PortfolioItemInput],
        *,
        budget: float,
        quotes: dict[str, TickerQuote],
        names: dict[str, str],
        sectors: dict[str, PortfolioSector],
        returns: dict[str, tuple[float, date]],
        # ^ (retorno %, fecha de la vela base)
    ) -> list[PortfolioAllocationItem]:
        """Resuelve cada posición y después normaliza los porcentajes sobre lo efectivamente
        asignado.

        Dos pasadas y no una: `percentage_of_total` se mide sobre el capital ASIGNADO, y ese total no
        se conoce hasta haber redondeado todas las unidades. Calcularlo en la primera pasada daría
        porcentajes que no suman 100.
        """

        resolved: list[_Resolved] = []

        for item in inputs:
            symbol = item.normalized_ticker
            quote = quotes.get(symbol)
            market_price = quote.last_price if quote is not None else None

            if item.custom_price is not None:
                effective: float | None = item.custom_price
            else:
                effective = market_price

            if effective is None:
                resolved.append(
                    _Resolved(item, market_price, None, 0, 0.0, _NOTE_NO_PRICE)
                )
                continue
            if effective < MIN_USABLE_PRICE:
                resolved.append(
                    _Resolved(
                        item, market_price, effective, 0, 0.0, _NOTE_PRICE_TOO_LOW
                    )
                )
                continue

            wanted = target_amount(item, budget=budget, price=effective)
            # Con `UNITS` el usuario ya dijo la cantidad: se pisa a entero por abajo igual que el
            # resto (2,7 acciones no se compran), pero no se recalcula desde el monto.
            units = (
                math.floor(item.allocation_value)
                if item.allocation_type == AllocationType.UNITS
                else units_for(wanted, effective)
            )
            invested = round(units * effective, 2)
            note = _NOTE_UNITS_BELOW_ONE if units == 0 else None
            resolved.append(
                _Resolved(item, market_price, effective, units, invested, note)
            )

        total_invested = sum(entry.invested for entry in resolved)

        items: list[PortfolioAllocationItem] = []
        for item, market_price, effective, units, invested, note in resolved:
            symbol = item.normalized_ticker
            measured = returns.get(symbol)
            if measured is None and effective is not None and note is None:
                note = _NOTE_NO_HISTORY
            sector = sectors.get(symbol, PortfolioSector.SIN_CLASIFICAR)

            items.append(
                PortfolioAllocationItem(
                    ticker=symbol,
                    name=names.get(symbol),
                    sector=sector,
                    sector_label=sector_label(sector),
                    market_price=market_price,
                    effective_price=effective,
                    is_custom_price=item.custom_price is not None,
                    price_source=(
                        PriceSource.CUSTOM
                        if item.custom_price is not None
                        else PriceSource.MARKET
                        if market_price is not None
                        else PriceSource.UNAVAILABLE
                    ),
                    units=units,
                    invested_amount=invested,
                    percentage_of_total=_percentage(invested, total_invested),
                    return_1y_pct=measured[0] if measured is not None else None,
                    return_1y_from_date=measured[1] if measured is not None else None,
                    note=note,
                )
            )
        return items

    async def _quotes(self, inputs: list[PortfolioItemInput]) -> dict[str, TickerQuote]:
        """Cotizaciones de TODOS los símbolos, incluidos los que traen `custom_price`.

        Se piden igual porque `market_price` viaja en la respuesta al lado del efectivo: con un precio
        esperado, ver el de mercado al lado es lo que permite juzgar si el supuesto es agresivo. Lo
        único que evita la llamada es que no haya proveedor configurado.
        """

        market = self._market
        if market is None or not inputs:
            return {}

        try:
            quotes = await market.get_quotes(
                [(item.normalized_ticker, item.asset_type) for item in inputs]
            )
        except Exception as exc:  # noqa: BLE001 — `MarketDataService` ya degrada por símbolo sin
            # lanzar; esto es una red de seguridad ante un bug inesperado, y una cartera entera no
            # debe caerse porque el proveedor tosa.
            logger.warning("portfolio_builder_quotes_failed", extra={"error": str(exc)})
            return {}

        return {quote.ticker: quote for quote in quotes}

    async def _names(self, inputs: list[PortfolioItemInput]) -> dict[str, str]:
        """Nombre de cada símbolo, del catálogo local. Un nombre ausente no degrada nada: la posición
        se muestra con su ticker, que es lo que el usuario escribió.
        """

        found = await asyncio.gather(
            *(self._catalog.find_name(item.normalized_ticker) for item in inputs),
            return_exceptions=True,
        )
        names: dict[str, str] = {}
        for item, name in zip(inputs, found, strict=True):
            if isinstance(name, BaseException) or name is None:
                continue
            names[item.normalized_ticker] = name
        return names

    async def _returns_1y(
        self, inputs: list[PortfolioItemInput], *, reference_day: date
    ) -> dict[str, tuple[float, date]]:
        """Retorno del último año por símbolo, contra precios REALES.

        Se mide close de hace un año contra close actual, los dos del proveedor. El precio
        personalizado no participa: lo que hizo el activo el año pasado no cambia porque el usuario
        suponga otro precio de entrada, y mezclarlos daría un "retorno" sin referente.
        """

        market = self._market
        if market is None or not inputs:
            return {}

        target = reference_day - timedelta(days=_YEAR_LOOKBACK_DAYS)
        start = target - timedelta(days=_YEAR_WINDOW_DAYS)

        histories = await asyncio.gather(
            *(
                market.get_history(
                    item.normalized_ticker, start=start, end=reference_day
                )
                for item in inputs
            ),
            return_exceptions=True,
        )

        returns: dict[str, tuple[float, date]] = {}
        for item, history in zip(inputs, histories, strict=True):
            if isinstance(history, BaseException):
                logger.warning(
                    "portfolio_builder_history_failed",
                    extra={"ticker": item.normalized_ticker, "error": str(history)},
                )
                continue
            measured = _return_from_history(history, target=target)
            if measured is not None:
                returns[item.normalized_ticker] = measured
        return returns

    def _availability(
        self, *, total: int, priced: int, sector_reason: str | None
    ) -> tuple[DataAvailability, str | None]:
        """Disponibilidad de la simulación entera.

        `UNAVAILABLE` solo cuando NINGUNA posición tiene precio: con una sola cotizada hay reparto que
        mostrar, y llamar a eso "no disponible" escondería el resultado que sí existe.
        """

        if priced == 0:
            reason = (
                _REASON_NO_MARKET_SOURCE
                if self._market is None
                else _REASON_SOME_PRICES_MISSING
            )
            return DataAvailability.UNAVAILABLE, reason
        if priced < total:
            return DataAvailability.PARTIAL, _REASON_SOME_PRICES_MISSING
        if sector_reason is not None:
            return DataAvailability.PARTIAL, sector_reason
        return DataAvailability.AVAILABLE, None

    def _notes(
        self, items: list[PortfolioAllocationItem], *, over_budget: float | None
    ) -> list[str]:
        notes = [_NOTE_WHOLE_UNITS]
        if any(item.is_custom_price for item in items):
            notes.append(_NOTE_CUSTOM_PRICE_WEIGHTS)
        if any(item.return_1y_pct is not None for item in items):
            notes.append(_NOTE_RETURN_IS_HISTORICAL)
        if over_budget is not None:
            notes.append(
                f"Lo pedido supera el presupuesto en US$ {over_budget:,.2f}. No se recortó ninguna "
                "posición: elegir a cuál sacarle capital es una decisión tuya, no del cálculo."
            )
        return notes


def _return_from_history(
    history: TickerHistory, *, target: date
) -> tuple[float, date] | None:
    """Retorno entre la vela más cercana a `target` y la última disponible.

    Necesita DOS velas distintas: con una sola, el "retorno" sería 0% por construcción y se leería
    como "el activo no se movió en un año". La fecha que devuelve es la de la vela base efectivamente
    usada, no `target`, porque es la única que hace verificable el número.
    """

    if len(history.bars) < 2:
        return None

    target_ms = (
        datetime(target.year, target.month, target.day, tzinfo=timezone.utc).timestamp()
        * 1000
    )
    base = min(history.bars, key=lambda bar: abs(bar.t - target_ms))
    latest = max(history.bars, key=lambda bar: bar.t)

    if base.t == latest.t or base.c <= 0:
        return None

    # La vela base tiene que estar CERCA del objetivo, no solo ser la más cercana de las que vinieron.
    # Un proveedor que devuelve un mes de historia igual tiene una vela "más cercana a hace un año", y
    # sin este control su retorno mensual viajaría en un campo llamado `return_1y_pct`. Antes que un
    # número mal etiquetado, ninguno.
    if abs(base.t - target_ms) > _YEAR_WINDOW_DAYS * 86_400_000:
        return None

    change = (latest.c - base.c) / base.c * 100
    base_day = datetime.fromtimestamp(base.t / 1000, tz=timezone.utc).date()
    return round(change, 2), base_day
