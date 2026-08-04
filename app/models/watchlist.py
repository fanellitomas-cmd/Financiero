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
