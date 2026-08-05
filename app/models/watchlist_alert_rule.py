"""Tabla `watchlist_alert_rules`: las reglas de alerta que el usuario configura sobre un item de
su Watchlist.

Tabla propia y no columnas nuevas en `watchlists` porque la relación es 1:N y no 1:1: un usuario
que sigue NVDA quiere razonablemente avisos por variación de precio Y por noticia grave, y
meterlas como columnas del item forzaría "una regla de cada tipo o ninguna" en la misma fila,
mezclando la configuración de tres cosas distintas en un solo registro.

Las columnas específicas de cada tipo son nullable y solo se leen para su propio `alert_type` (ver
`app/services/watchlist_alert_service.py`). Se validan en la capa de schemas, que rechaza una
regla con campos de otro tipo en vez de ignorarlos en silencio: una regla que parece configurada
pero cuyo parámetro nadie lee es peor que un error de validación.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal
from typing import TYPE_CHECKING

from sqlalchemy import Boolean, DateTime, ForeignKey, Numeric, UniqueConstraint, func
from sqlalchemy import Enum as SAEnum
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.enums import AlertRuleType, TrendBreakDirection, TrendHorizon
from src.validation.domain_models import AlertSeverity

if TYPE_CHECKING:
    from app.models.watchlist import WatchlistItem


class WatchlistAlertRule(Base):
    __tablename__ = "watchlist_alert_rules"
    __table_args__ = (
        # Una regla por tipo y por item: dos reglas PRICE sobre el mismo ticker solo pueden
        # contradecirse (¿avisa al 3% o al 8%?), y la que "gana" sería la que el ORM devuelva
        # primero. Se prohíbe en el esquema, no solo en la API.
        UniqueConstraint(
            "watchlist_item_id", "alert_type", name="uq_alert_rule_item_type"
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)

    # FK al item y no al par (user_id, ticker): borrar el ticker de la watchlist tiene que
    # llevarse sus reglas, y el CASCADE lo garantiza en la base en vez de depender de que la capa
    # de aplicación se acuerde de limpiarlas.
    watchlist_item_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("watchlists.id", ondelete="CASCADE"), nullable=False, index=True
    )

    alert_type: Mapped[AlertRuleType] = mapped_column(
        SAEnum(AlertRuleType, native_enum=False, length=24), nullable=False
    )

    # Apagar una regla sin borrarla: el usuario que silencia un aviso por una semana no debería
    # perder el umbral que ajustó.
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)

    # --- Parámetros de PRICE ---
    # Espejo de `WatchlistItem.alert_threshold_pct`: los dos se mantienen sincronizados desde
    # `WatchlistAlertRuleService` para que exista UN solo umbral efectivo por ticker (el item lo
    # expone en `GET /watchlist`, la regla lo evalúa).
    threshold_pct: Mapped[Decimal | None] = mapped_column(Numeric(5, 2), nullable=True)

    # --- Parámetros de NEWS_SEVERITY ---
    min_severity: Mapped[AlertSeverity | None] = mapped_column(
        SAEnum(AlertSeverity, native_enum=False, length=16), nullable=True
    )
    # Non-nullable con default False y no nullable: es un booleano de tres estados solo si se lo
    # deja nullable, y "no aplica" ya lo dice `alert_type`. Solo se lee para NEWS_SEVERITY.
    require_negative_sentiment: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False
    )

    # --- Parámetros de TREND_BREAK ---
    trend_horizon: Mapped[TrendHorizon | None] = mapped_column(
        SAEnum(TrendHorizon, native_enum=False, length=16), nullable=True
    )
    trend_direction: Mapped[TrendBreakDirection | None] = mapped_column(
        SAEnum(TrendBreakDirection, native_enum=False, length=16), nullable=True
    )
    min_probability_pct: Mapped[Decimal | None] = mapped_column(
        Numeric(5, 2), nullable=True
    )

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )

    item: Mapped[WatchlistItem] = relationship(
        "WatchlistItem", back_populates="alert_rules"
    )
