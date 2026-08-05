"""Schemas de `/api/v1/watchlist/alerts` — las reglas de alerta configurables por ticker.

Un solo schema con los parámetros de los tres tipos y un validador que exige los del tipo elegido
y **rechaza** los de los otros. La alternativa (tres schemas con un discriminador) daría un
OpenAPI más lindo pero un cliente más difícil: la app tiene un solo formulario que cambia de
campos según el tipo, y un `anyOf` de tres variantes lo obliga a armar tres cuerpos distintos.

Rechazar los campos de otro tipo, en vez de ignorarlos, es la decisión importante: una regla
`PRICE` que llegó con `min_severity` significa que alguien creyó estar configurando algo que
nadie va a leer, y guardarla en silencio deja al usuario esperando un aviso que nunca llega.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.models.enums import AlertRuleType, TrendBreakDirection, TrendHorizon
from src.validation.domain_models import AlertSeverity

# Campos que solo tienen sentido para su propio tipo. Se usa tanto para exigirlos como para
# rechazar los ajenos, así que la tabla es una sola y no se pueden desincronizar.
_FIELDS_BY_TYPE: dict[AlertRuleType, frozenset[str]] = {
    AlertRuleType.PRICE: frozenset({"threshold_pct"}),
    AlertRuleType.NEWS_SEVERITY: frozenset(
        {"min_severity", "require_negative_sentiment"}
    ),
    AlertRuleType.TREND_BREAK: frozenset(
        {"trend_horizon", "trend_direction", "min_probability_pct"}
    ),
}

_ALL_TYPE_FIELDS: frozenset[str] = frozenset(
    field for fields in _FIELDS_BY_TYPE.values() for field in fields
)


def foreign_fields_for(alert_type: AlertRuleType, provided: set[str]) -> list[str]:
    """De los campos que trajo el request, cuáles pertenecen a OTRO tipo de regla.

    Público y compartido con el servicio: el alta lo usa desde el validador del schema (donde el
    tipo viaja en el cuerpo) y el PATCH desde el servicio (donde el tipo recién se conoce al leer
    la fila). Una sola tabla y una sola función para que las dos validaciones no puedan divergir.
    """

    return sorted((provided & _ALL_TYPE_FIELDS) - _FIELDS_BY_TYPE[alert_type])


def foreign_fields_message(alert_type: AlertRuleType, foreign: list[str]) -> str:
    return (
        f"Una regla {alert_type.value} no usa {', '.join(foreign)}: esos parámetros "
        "pertenecen a otro tipo de alerta y no se evaluarían."
    )


class WatchlistAlertRuleCreate(BaseModel):
    """Alta de una regla. Los parámetros del tipo elegido son opcionales: omitidos, el servicio
    aplica los defaults del producto (ver `app/services/watchlist_alert_service.py`) — que para
    `PRICE` es el umbral que el usuario ya tenía configurado en su item de watchlist.
    """

    # strict=False (default) deliberado, igual que `WatchlistItemCreate`: valida JSON externo de
    # un request HTTP, donde Decimal y Enum llegan como string/number y necesitan coerción.
    model_config = ConfigDict(extra="forbid")

    # Se identifica el activo por ticker y no por el UUID del item: el cliente que arma la
    # pantalla de alertas tiene el símbolo a mano, y obligarlo a resolver el id primero sería un
    # request de ida y vuelta por cada alerta que se configura.
    ticker: str = Field(min_length=1, max_length=20)
    alert_type: AlertRuleType
    enabled: bool = True

    threshold_pct: Decimal | None = Field(default=None, gt=0, le=100)
    min_severity: AlertSeverity | None = None
    require_negative_sentiment: bool | None = None
    trend_horizon: TrendHorizon | None = None
    trend_direction: TrendBreakDirection | None = None
    min_probability_pct: Decimal | None = Field(default=None, ge=0, le=100)

    @model_validator(mode="after")
    def _check_fields_match_type(self) -> WatchlistAlertRuleCreate:
        foreign = foreign_fields_for(self.alert_type, set(self.model_fields_set))
        if foreign:
            raise ValueError(foreign_fields_message(self.alert_type, foreign))
        return self


class WatchlistAlertRuleUpdate(BaseModel):
    """PATCH parcial: solo se tocan los campos presentes.

    No se puede cambiar `alert_type` ni `ticker` — eso sería otra regla, no una edición de esta, y
    permitirlo dejaría una fila con los parámetros de su tipo anterior. Para cambiar de tipo se
    borra y se crea.
    """

    model_config = ConfigDict(extra="forbid")

    enabled: bool | None = None
    threshold_pct: Decimal | None = Field(default=None, gt=0, le=100)
    min_severity: AlertSeverity | None = None
    require_negative_sentiment: bool | None = None
    trend_horizon: TrendHorizon | None = None
    trend_direction: TrendBreakDirection | None = None
    min_probability_pct: Decimal | None = Field(default=None, ge=0, le=100)


class WatchlistAlertRuleRead(BaseModel):
    """Una regla tal como la devuelve la API.

    Se exponen todos los parámetros, incluidos los `None` de los tipos que no aplican: un cliente
    que renderiza el formulario a partir de esta respuesta necesita saber que el campo existe y
    está vacío, no que desapareció.
    """

    model_config = ConfigDict(strict=True, extra="forbid", from_attributes=True)

    id: UUID
    watchlist_item_id: UUID
    ticker: str
    alert_type: AlertRuleType
    enabled: bool

    threshold_pct: Decimal | None = None
    min_severity: AlertSeverity | None = None
    require_negative_sentiment: bool = False
    trend_horizon: TrendHorizon | None = None
    trend_direction: TrendBreakDirection | None = None
    min_probability_pct: Decimal | None = None

    created_at: datetime
    updated_at: datetime
