"""`/api/v1/watchlist/alerts` — ABM de las reglas de alerta contextuales de la Watchlist.

No confundir con `GET /api/v1/alerts` (`app/api/v1/alerts.py`), que es el Centro de
Notificaciones: aquello es el historial de lo que ya pasó, esto es la configuración de qué querés
que te avisen. Viven en prefijos distintos justamente para que no se mezclen.

Todo scopeado a `CurrentUser`: no se puede leer, modificar ni borrar una regla de otro usuario
aunque se conozca su UUID, y solo se pueden configurar reglas sobre tickers que el usuario sigue.
"""

from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, status

from app.api.deps import CurrentUser, WatchlistAlertRules
from app.models.enums import AlertRuleType
from app.schemas.watchlist_alert import (
    WatchlistAlertRuleCreate,
    WatchlistAlertRuleRead,
    WatchlistAlertRuleUpdate,
)
from app.services.watchlist_alert_service import (
    DuplicateRuleError,
    ForeignRuleFieldError,
    RuleNotFoundError,
    TickerNotInWatchlistError,
)

router = APIRouter(prefix="/watchlist", tags=["watchlist"])

_RULE_NOT_FOUND = HTTPException(
    status_code=status.HTTP_404_NOT_FOUND, detail="Regla de alerta no encontrada."
)


@router.get(
    "/alerts",
    response_model=list[WatchlistAlertRuleRead],
    summary="Reglas de alerta configuradas",
)
async def list_alert_rules(
    current_user: CurrentUser,
    rules: WatchlistAlertRules,
    ticker: Annotated[str | None, Query(min_length=1, max_length=20)] = None,
    alert_type: Annotated[AlertRuleType | None, Query()] = None,
) -> list[WatchlistAlertRuleRead]:
    """Devuelve las reglas de TODOS los tickers del usuario, filtrables por símbolo y por tipo.

    Un ticker sin reglas simplemente no aparece: eso significa que recibe todas las alertas que el
    motor produzca sobre él, que es el comportamiento por defecto.
    """

    return await rules.list_rules(current_user.id, ticker=ticker, alert_type=alert_type)


@router.post(
    "/alerts",
    response_model=WatchlistAlertRuleRead,
    status_code=status.HTTP_201_CREATED,
    summary="Configurar una regla de alerta",
)
async def create_alert_rule(
    payload: WatchlistAlertRuleCreate,
    current_user: CurrentUser,
    rules: WatchlistAlertRules,
) -> WatchlistAlertRuleRead:
    """Crea una regla `PRICE`, `NEWS_SEVERITY` o `TREND_BREAK` sobre un ticker de la watchlist.

    Los parámetros del tipo son opcionales: omitidos, se aplican los defaults del producto (para
    `PRICE`, el umbral que el usuario ya tenía configurado en ese item). Los parámetros de OTRO
    tipo se rechazan con 422 en vez de ignorarse — una regla que parece configurada pero cuyo
    parámetro nadie lee es peor que un error.
    """

    try:
        return await rules.create_rule(current_user.id, payload)
    except TickerNotInWatchlistError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=(
                f"{exc} no está en tu watchlist: agregalo antes de configurarle una alerta."
            ),
        ) from exc
    except DuplicateRuleError as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"Ya tenés una regla {exc} para ese ticker. Modificá la existente en vez de "
                "crear otra."
            ),
        ) from exc


@router.patch(
    "/alerts/{rule_id}",
    response_model=WatchlistAlertRuleRead,
    summary="Modificar una regla de alerta",
)
async def update_alert_rule(
    rule_id: UUID,
    payload: WatchlistAlertRuleUpdate,
    current_user: CurrentUser,
    rules: WatchlistAlertRules,
) -> WatchlistAlertRuleRead:
    """PATCH parcial. No se puede cambiar el tipo ni el ticker de una regla: eso sería otra regla,
    y permitirlo dejaría la fila con los parámetros de su tipo anterior.
    """

    try:
        return await rules.update_rule(current_user.id, rule_id, payload)
    except RuleNotFoundError as exc:
        raise _RULE_NOT_FOUND from exc
    except ForeignRuleFieldError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=str(exc)
        ) from exc


@router.delete(
    "/alerts/{rule_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Eliminar una regla de alerta",
)
async def delete_alert_rule(
    rule_id: UUID, current_user: CurrentUser, rules: WatchlistAlertRules
) -> None:
    """Borrar la última regla de un ticker lo devuelve al comportamiento por defecto: vuelve a
    recibir todas las alertas. Para dejar de recibir avisos sin borrar la configuración está
    `enabled=false`.
    """

    try:
        await rules.delete_rule(current_user.id, rule_id)
    except RuleNotFoundError as exc:
        raise _RULE_NOT_FOUND from exc
