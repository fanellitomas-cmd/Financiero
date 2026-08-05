"""Tabla `watchlists`."""

from __future__ import annotations

import uuid
from decimal import Decimal
from typing import TYPE_CHECKING

from sqlalchemy import Boolean, ForeignKey, Numeric, String, UniqueConstraint
from sqlalchemy import Enum as SAEnum
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.config import app_settings
from app.core.database import Base
from app.models.enums import AssetType, ExchangeType

if TYPE_CHECKING:
    from app.models.user import User
    from app.models.watchlist_alert_rule import WatchlistAlertRule


class WatchlistItem(Base):
    __tablename__ = "watchlists"
    __table_args__ = (
        UniqueConstraint("user_id", "ticker", name="uq_watchlist_user_ticker"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    ticker: Mapped[str] = mapped_column(String(20), nullable=False, index=True)
    asset_type: Mapped[AssetType] = mapped_column(
        SAEnum(AssetType, native_enum=False, length=16), nullable=False
    )
    # Umbral de la regla de precio. Sigue viviendo acá (y no solo en `watchlist_alert_rules`)
    # porque es el único parámetro de alerta que la app expone desde antes de las reglas
    # contextuales, y moverlo rompería `GET /watchlist`. `WatchlistAlertRuleService` mantiene los
    # dos lados sincronizados: hay un solo umbral efectivo por ticker, no dos que se contradigan.
    alert_threshold_pct: Mapped[Decimal] = mapped_column(
        Numeric(5, 2),
        nullable=False,
        default=Decimal(app_settings.default_alert_threshold_pct),
    )
    enable_beginner_mode: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False
    )

    # Se completa automáticamente desde el catálogo `tickers` al crear el item (ver
    # `app/api/v1/watchlist.py`) — el usuario no lo elige. Nullable a propósito: una cripto no
    # cotiza en NASDAQ/NYSE, y una acción cuyo símbolo todavía no está en el catálogo (nunca se
    # sincronizó, o es nuevo) se guarda sin bolsa en vez de rechazarse.
    exchange: Mapped[ExchangeType | None] = mapped_column(
        SAEnum(ExchangeType, native_enum=False, length=16), nullable=True
    )

    user: Mapped[User] = relationship("User", back_populates="watchlist_items")

    # `lazy="selectin"` no: las reglas se consultan explícitamente cuando se las necesita (la API
    # de reglas y el filtrado de despacho), y cargarlas en cada `GET /watchlist` sería un JOIN por
    # cada listado que la pantalla de watchlist no usa.
    #
    # Sin `passive_deletes=True`, a propósito: la FK declara `ON DELETE CASCADE`, pero SQLite —la
    # base de desarrollo y la de los tests— ignora las foreign keys salvo que se prenda
    # `PRAGMA foreign_keys=ON` por conexión, así que delegar el borrado en la base dejaría reglas
    # huérfanas apuntando a un item que ya no existe. Con el cascade del ORM, borrar el ticker se
    # lleva su configuración en cualquier motor, al costo de un SELECT extra en el delete.
    alert_rules: Mapped[list[WatchlistAlertRule]] = relationship(
        "WatchlistAlertRule",
        back_populates="item",
        cascade="all, delete-orphan",
    )
