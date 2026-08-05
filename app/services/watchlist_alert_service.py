"""Reglas de alerta contextuales de la Watchlist: ABM (`/api/v1/watchlist/alerts`) y evaluación
de si una alerta concreta le corresponde a un usuario concreto.

Hasta acá el sistema tenía un solo parámetro de alerta por ticker (`alert_threshold_pct`) que
**nada leía**: todos los que seguían un símbolo recibían todo lo que el motor produjera sobre él.
Este módulo es el que convierte esa configuración en una decisión de entrega.

Tres tipos de regla, y la diferencia entre el primero y los otros dos es el punto del bloque:

  - `PRICE` mira el movimiento: "avisame si se mueve más de 5%".
  - `NEWS_SEVERITY` mira la severidad de lo que pasó y, opcionalmente, que el análisis lo haya
    interpretado como negativo: "avisame si hay una noticia grave o el sentimiento se da vuelta".
  - `TREND_BREAK` mira la proyección por horizonte: "avisame si se rompe la tendencia de mediano
    plazo".

Un umbral de precio no distingue una caída del 5% por nerviosismo de una del 5% por deterioro
real. Las reglas contextuales se evalúan contra la interpretación que ya produjo el motor
(`AssetProjection`), que es justamente la información que esa distinción necesita.

**Regla de compatibilidad**: un item SIN reglas habilitadas recibe todo, como siempre. Las reglas
son un filtro que el usuario opta por poner, no un permiso que tenga que pedir — si estrenar este
módulo dejara a todo el mundo sin alertas hasta que configure algo, sería una regresión disfrazada
de feature.
"""

from __future__ import annotations

import logging
from collections.abc import Iterable
from decimal import Decimal
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
from sqlalchemy.orm import selectinload

from app.models.enums import AlertRuleType, TrendBreakDirection, TrendHorizon
from app.models.watchlist import WatchlistItem
from app.models.watchlist_alert_rule import WatchlistAlertRule
from app.schemas.watchlist_alert import (
    WatchlistAlertRuleCreate,
    WatchlistAlertRuleRead,
    WatchlistAlertRuleUpdate,
    foreign_fields_for,
    foreign_fields_message,
)
from src.validation.domain_models import (
    AlertSeverity,
    AlertTriggerType,
    AssetProjection,
    PushNotificationPayload,
)

logger = logging.getLogger(__name__)

# Defaults del producto cuando el usuario crea una regla sin especificar sus parámetros.
_DEFAULT_MIN_SEVERITY = AlertSeverity.HIGH
_DEFAULT_TREND_HORIZON = TrendHorizon.MEDIANO
_DEFAULT_TREND_DIRECTION = TrendBreakDirection.BAJISTA
# 50% no es arbitrario: es el punto donde un escenario deja de ser uno más entre tres y pasa a ser
# el más probable por mayoría absoluta.
_DEFAULT_MIN_PROBABILITY_PCT = Decimal("50.0")

# El orden es explícito y no `list(AlertSeverity).index(...)`: comparar por posición ataría el
# significado de "más grave" al orden en que están escritos los miembros del enum, y reordenarlos
# (o insertar uno nuevo en el medio) cambiaría en silencio qué alertas pasan el filtro.
_SEVERITY_ORDER: dict[AlertSeverity, int] = {
    AlertSeverity.LOW: 0,
    AlertSeverity.MEDIUM: 1,
    AlertSeverity.HIGH: 2,
    AlertSeverity.CRITICAL: 3,
}

# Horizonte del producto -> horizonte del motor. La traducción vive acá y no en el enum para que
# `app/` no tenga que importar el vocabulario de `src/` en su capa de modelos.
_HORIZON_TO_ENGINE: dict[TrendHorizon, str] = {
    TrendHorizon.CORTO: "CORTO_1_14D",
    TrendHorizon.MEDIANO: "MEDIANO_1_6M",
    TrendHorizon.LARGO: "LARGO_1_3A",
}

# Disparadores que cuentan como "algo pasó con esta empresa", contra los que son movimiento de
# mercado. Una regla NEWS_SEVERITY quiere los primeros: quien la configuró ya tiene PRICE para el
# movimiento, y hacer que además le llegue todo pico de volumen la volvería redundante.
_CONTEXTUAL_TRIGGERS: frozenset[AlertTriggerType] = frozenset(
    {
        AlertTriggerType.NEWS_SHOCK,
        AlertTriggerType.FUNDAMENTAL_CHANGE,
        AlertTriggerType.ON_CHAIN_ANOMALY,
    }
)


class HorizonOutlook(BaseModel):
    """El escenario dominante de un horizonte, ya resuelto desde el `AssetProjection`."""

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    direction: Literal["ALCISTA", "NEUTRAL", "BAJISTA"]
    probability_pct: Decimal
    confidence_level: Literal["BAJA", "MEDIA", "ALTA"]


class AlertEvaluationContext(BaseModel):
    """Todo lo que hace falta para decidir si una regla matchea, ya extraído del payload y de la
    `MarketAlert` que lo originó.

    Existe como modelo propio y no se le pasa el payload crudo a cada regla porque la extracción
    (buscar el escenario dominante de un horizonte, traducir vocabularios) es la parte con lógica:
    hacerla una vez y testearla sola es mejor que repetirla adentro de tres ramas de `match`.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    ticker: str
    severity: AlertSeverity
    trigger_type: AlertTriggerType | None = None
    # Variación porcentual que disparó la alerta, en valor absoluto. `None` cuando la alerta no
    # nació de un movimiento de precio — y ahí una regla PRICE NO matchea, en vez de asumir cero o
    # asumir que sí: no se puede afirmar que se cruzó un umbral que nadie midió.
    day_change_pct: Decimal | None = None
    classification: (
        Literal["REACCION_EMOCIONAL", "DETERIORO_FUNDAMENTAL", "INDETERMINADO"] | None
    ) = None
    horizon_outlooks: dict[TrendHorizon, HorizonOutlook] = Field(default_factory=dict)


def _dominant_outlook(
    projection: AssetProjection,
) -> dict[TrendHorizon, HorizonOutlook]:
    engine_to_product = {
        engine: product for product, engine in _HORIZON_TO_ENGINE.items()
    }
    outlooks: dict[TrendHorizon, HorizonOutlook] = {}
    for horizon in projection.horizons:
        product_horizon = engine_to_product.get(horizon.horizon)
        if product_horizon is None or not horizon.scenarios:
            continue
        dominant = max(horizon.scenarios, key=lambda scenario: scenario.probability_pct)
        outlooks[product_horizon] = HorizonOutlook(
            direction=dominant.label,
            probability_pct=dominant.probability_pct,
            confidence_level=horizon.confidence_level,
        )
    return outlooks


def build_evaluation_context(
    payload: PushNotificationPayload,
    *,
    trigger_type: AlertTriggerType | None = None,
    trigger_value: Decimal | None = None,
) -> AlertEvaluationContext:
    """Arma el contexto de evaluación a partir del payload del Nodo 5 y, si se conoce, del
    disparador que lo originó.

    `trigger_type`/`trigger_value` llegan por parámetro y no se extraen del payload porque el
    payload no los lleva: son de la `MarketAlert` del Nodo 1, que el grafo tiene en su estado. Sin
    ellos el contexto igual se arma (severidad y proyección alcanzan para NEWS_SEVERITY y
    TREND_BREAK) y solo las reglas PRICE quedan sin poder afirmar nada.
    """

    projection = payload.full_analysis_json
    return AlertEvaluationContext(
        ticker=payload.ticker,
        severity=payload.urgency_level,
        trigger_type=trigger_type,
        day_change_pct=(
            abs(trigger_value)
            if trigger_value is not None and trigger_type == AlertTriggerType.PRICE_MOVE
            else None
        ),
        classification=projection.classification if projection is not None else None,
        horizon_outlooks=(
            _dominant_outlook(projection) if projection is not None else {}
        ),
    )


def rule_matches(rule: WatchlistAlertRule, context: AlertEvaluationContext) -> bool:
    """¿Esta alerta concreta cumple lo que la regla pide?

    Una regla apagada nunca matchea. Cuando falta el dato que la regla necesita, la respuesta es
    **no**: una regla que dispara ante la duda convierte "avisame solo si es grave" en "avisame
    siempre", que es exactamente lo que el usuario pidió evitar.
    """

    if not rule.enabled:
        return False

    match rule.alert_type:
        case AlertRuleType.PRICE:
            threshold = rule.threshold_pct
            if threshold is None or context.day_change_pct is None:
                return False
            return context.day_change_pct >= threshold

        case AlertRuleType.NEWS_SEVERITY:
            minimum = rule.min_severity or _DEFAULT_MIN_SEVERITY
            if _SEVERITY_ORDER[context.severity] < _SEVERITY_ORDER[minimum]:
                return False
            if context.trigger_type not in _CONTEXTUAL_TRIGGERS:
                return False
            if not rule.require_negative_sentiment:
                return True
            # "Sentimiento negativo" no es una etiqueta que el motor emita: se deriva de lo que sí
            # emite — que el análisis haya concluido deterioro real, o que el corto plazo proyecte
            # baja. Cualquiera de las dos alcanza.
            if context.classification == "DETERIORO_FUNDAMENTAL":
                return True
            short_term = context.horizon_outlooks.get(TrendHorizon.CORTO)
            return short_term is not None and short_term.direction == "BAJISTA"

        case AlertRuleType.TREND_BREAK:
            horizon = rule.trend_horizon or _DEFAULT_TREND_HORIZON
            outlook = context.horizon_outlooks.get(horizon)
            if outlook is None:
                return False
            # Una proyección que el propio motor marcó de confianza BAJA no despierta a nadie: es
            # el caso donde el sistema ya dijo que no tiene datos suficientes para sostenerla.
            if outlook.confidence_level == "BAJA":
                return False

            direction = rule.trend_direction or _DEFAULT_TREND_DIRECTION
            if direction != TrendBreakDirection.CUALQUIERA:
                if outlook.direction != direction.value:
                    return False
            elif outlook.direction == "NEUTRAL":
                # `CUALQUIERA` es "alcista o bajista", no "cualquier cosa": un horizonte neutral es
                # justamente la ausencia de un quiebre de tendencia.
                return False

            min_probability = rule.min_probability_pct
            if min_probability is None:
                min_probability = _DEFAULT_MIN_PROBABILITY_PCT
            return outlook.probability_pct >= min_probability


def select_eligible_items(
    items: Iterable[tuple[UUID, list[WatchlistAlertRule]]],
    context: AlertEvaluationContext,
) -> set[UUID]:
    """Ids de los items de watchlist que deben recibir esta alerta.

    Un item sin reglas habilitadas es elegible (ver la regla de compatibilidad en el docstring del
    módulo). Con reglas habilitadas, alcanza con que UNA matchee: son un OR, no un AND — el usuario
    que configura "precio > 5%" y "noticia grave" está pidiendo las dos cosas por separado, no la
    intersección de ambas.
    """

    eligible: set[UUID] = set()
    for item_id, rules in items:
        enabled = [rule for rule in rules if rule.enabled]
        if not enabled or any(rule_matches(rule, context) for rule in enabled):
            eligible.add(item_id)
    return eligible


def to_read(rule: WatchlistAlertRule, ticker: str) -> WatchlistAlertRuleRead:
    """`WatchlistAlertRuleRead` a partir de la fila y del ticker de su item.

    El ticker llega por parámetro y no vía `rule.item.ticker`: acceder a la relación fuera de la
    sesión (o sin haberla cargado) dispararía un lazy load que en async explota con
    `MissingGreenlet`, y el error aparecería recién al serializar la respuesta.
    """

    return WatchlistAlertRuleRead(
        id=rule.id,
        watchlist_item_id=rule.watchlist_item_id,
        ticker=ticker,
        alert_type=rule.alert_type,
        enabled=rule.enabled,
        threshold_pct=rule.threshold_pct,
        min_severity=rule.min_severity,
        require_negative_sentiment=rule.require_negative_sentiment,
        trend_horizon=rule.trend_horizon,
        trend_direction=rule.trend_direction,
        min_probability_pct=rule.min_probability_pct,
        created_at=rule.created_at,
        updated_at=rule.updated_at,
    )


class RuleNotFoundError(Exception):
    """La regla no existe, o es de otro usuario. Un solo error para los dos casos a propósito: si
    "existe pero no es tuya" tuviera una respuesta distinta de "no existe", cualquiera podría
    enumerar reglas ajenas probando UUIDs.
    """


class TickerNotInWatchlistError(Exception):
    """No se puede configurar una alerta sobre un ticker que el usuario no sigue: la regla cuelga
    del item, y crearlo automáticamente metería el símbolo en su watchlist como efecto colateral de
    configurar un aviso.
    """


class DuplicateRuleError(Exception):
    """Ya existe una regla de ese tipo para ese ticker (ver la unique constraint del modelo)."""


class ForeignRuleFieldError(ValueError):
    """Un PATCH trajo un parámetro que no pertenece al tipo de la regla."""


def _reject_update_of_foreign_fields(
    alert_type: AlertRuleType, provided: set[str]
) -> None:
    """Mismo criterio que en el alta, pero acá no puede vivir en el schema: el tipo de la regla no
    viaja en el PATCH (no se puede cambiar), así que solo se conoce después de leer la fila.
    """

    foreign = foreign_fields_for(alert_type, provided)
    if foreign:
        raise ForeignRuleFieldError(foreign_fields_message(alert_type, foreign))


class WatchlistAlertRuleService:
    """ABM de reglas, siempre scopeado al usuario autenticado.

    Sin caché ni clientes externos: son lecturas y escrituras de la base local, baratas y que
    tienen que verse al instante — cachear la configuración del usuario haría que su propio cambio
    tarde en aparecer, que es el peor lugar donde poner una caché.
    """

    def __init__(self, session_factory: async_sessionmaker[AsyncSession]) -> None:
        self._session_factory = session_factory

    async def list_rules(
        self,
        user_id: UUID,
        *,
        ticker: str | None = None,
        alert_type: AlertRuleType | None = None,
    ) -> list[WatchlistAlertRuleRead]:
        async with self._session_factory() as session:
            statement = (
                select(WatchlistAlertRule, WatchlistItem.ticker)
                .join(
                    WatchlistItem,
                    WatchlistItem.id == WatchlistAlertRule.watchlist_item_id,
                )
                .where(WatchlistItem.user_id == user_id)
                .order_by(WatchlistItem.ticker, WatchlistAlertRule.alert_type)
            )
            if ticker is not None:
                statement = statement.where(WatchlistItem.ticker == ticker.upper())
            if alert_type is not None:
                statement = statement.where(WatchlistAlertRule.alert_type == alert_type)

            rows = (await session.execute(statement)).all()

        return [to_read(rule, item_ticker) for rule, item_ticker in rows]

    async def create_rule(
        self, user_id: UUID, payload: WatchlistAlertRuleCreate
    ) -> WatchlistAlertRuleRead:
        async with self._session_factory() as session:
            item = await session.scalar(
                select(WatchlistItem).where(
                    WatchlistItem.user_id == user_id,
                    WatchlistItem.ticker == payload.ticker.upper(),
                )
            )
            if item is None:
                raise TickerNotInWatchlistError(payload.ticker.upper())

            existing = await session.scalar(
                select(WatchlistAlertRule).where(
                    WatchlistAlertRule.watchlist_item_id == item.id,
                    WatchlistAlertRule.alert_type == payload.alert_type,
                )
            )
            if existing is not None:
                raise DuplicateRuleError(payload.alert_type.value)

            rule = WatchlistAlertRule(
                watchlist_item_id=item.id,
                alert_type=payload.alert_type,
                enabled=payload.enabled,
                **_defaults_for(payload, item),
            )
            session.add(rule)

            if (
                rule.alert_type == AlertRuleType.PRICE
                and rule.threshold_pct is not None
            ):
                # Un solo umbral efectivo: `GET /watchlist` sigue mostrando el del item, y la
                # evaluación usa el de la regla. Desincronizarlos haría que la app muestre 3% y
                # avise al 8%.
                item.alert_threshold_pct = rule.threshold_pct

            await session.commit()
            await session.refresh(rule)
            return to_read(rule, item.ticker)

    async def update_rule(
        self, user_id: UUID, rule_id: UUID, payload: WatchlistAlertRuleUpdate
    ) -> WatchlistAlertRuleRead:
        async with self._session_factory() as session:
            rule = await session.scalar(
                select(WatchlistAlertRule)
                .options(selectinload(WatchlistAlertRule.item))
                .join(
                    WatchlistItem,
                    WatchlistItem.id == WatchlistAlertRule.watchlist_item_id,
                )
                .where(
                    WatchlistAlertRule.id == rule_id,
                    WatchlistItem.user_id == user_id,
                )
            )
            if rule is None:
                raise RuleNotFoundError(str(rule_id))

            provided = payload.model_fields_set
            _reject_update_of_foreign_fields(rule.alert_type, provided)

            if payload.enabled is not None:
                rule.enabled = payload.enabled
            if payload.threshold_pct is not None:
                rule.threshold_pct = payload.threshold_pct
                rule.item.alert_threshold_pct = payload.threshold_pct
            if payload.min_severity is not None:
                rule.min_severity = payload.min_severity
            if payload.require_negative_sentiment is not None:
                rule.require_negative_sentiment = payload.require_negative_sentiment
            if payload.trend_horizon is not None:
                rule.trend_horizon = payload.trend_horizon
            if payload.trend_direction is not None:
                rule.trend_direction = payload.trend_direction
            if payload.min_probability_pct is not None:
                rule.min_probability_pct = payload.min_probability_pct

            await session.commit()
            await session.refresh(rule)
            return to_read(rule, rule.item.ticker)

    async def delete_rule(self, user_id: UUID, rule_id: UUID) -> None:
        async with self._session_factory() as session:
            rule = await session.scalar(
                select(WatchlistAlertRule)
                .join(
                    WatchlistItem,
                    WatchlistItem.id == WatchlistAlertRule.watchlist_item_id,
                )
                .where(
                    WatchlistAlertRule.id == rule_id,
                    WatchlistItem.user_id == user_id,
                )
            )
            if rule is None:
                raise RuleNotFoundError(str(rule_id))

            await session.delete(rule)
            await session.commit()


def _defaults_for(
    payload: WatchlistAlertRuleCreate, item: WatchlistItem
) -> dict[str, object]:
    """Parámetros de la regla, con los defaults del producto para lo que el cliente no mandó.

    Los campos de los otros tipos quedan en `None` y no se completan: el schema ya rechazó que
    vinieran, y dejarlos vacíos hace que la fila diga qué tipo de regla es con solo mirarla.

    El default de `PRICE` es el umbral que el usuario YA tenía en su item, no la constante global:
    quien venía usando 8% y crea su primera regla explícita no debería encontrarse con que se le
    reseteó a 3%.
    """

    match payload.alert_type:
        case AlertRuleType.PRICE:
            return {
                "threshold_pct": payload.threshold_pct
                if payload.threshold_pct is not None
                else item.alert_threshold_pct
            }
        case AlertRuleType.NEWS_SEVERITY:
            return {
                "min_severity": payload.min_severity or _DEFAULT_MIN_SEVERITY,
                "require_negative_sentiment": bool(payload.require_negative_sentiment),
            }
        case AlertRuleType.TREND_BREAK:
            return {
                "trend_horizon": payload.trend_horizon or _DEFAULT_TREND_HORIZON,
                "trend_direction": payload.trend_direction or _DEFAULT_TREND_DIRECTION,
                "min_probability_pct": payload.min_probability_pct
                if payload.min_probability_pct is not None
                else _DEFAULT_MIN_PROBABILITY_PCT,
            }
