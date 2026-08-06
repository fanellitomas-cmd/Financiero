"""Tabla `users`."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import DateTime, String, func
from sqlalchemy import Enum as SAEnum
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.enums import PlanType

if TYPE_CHECKING:
    from app.models.device_token import DeviceToken
    from app.models.folder import Folder
    from app.models.note import Note
    from app.models.watchlist import WatchlistItem


class User(Base):
    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    email: Mapped[str] = mapped_column(
        String(320), unique=True, index=True, nullable=False
    )
    hashed_password: Mapped[str] = mapped_column(String(255), nullable=False)
    plan_type: Mapped[PlanType] = mapped_column(
        SAEnum(PlanType, native_enum=False, length=16),
        nullable=False,
        default=PlanType.FREE,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    watchlist_items: Mapped[list[WatchlistItem]] = relationship(
        "WatchlistItem", back_populates="user", cascade="all, delete-orphan"
    )
    device_tokens: Mapped[list[DeviceToken]] = relationship(
        "DeviceToken", back_populates="user", cascade="all, delete-orphan"
    )

    # El Investment Lab del usuario. Acá SÍ va `delete-orphan`: borrar la cuenta se lleva sus
    # carpetas y notas, que no le sirven a nadie más. Es distinto del borrado de UNA carpeta, donde
    # las notas se conservan (ver `app/models/folder.py`).
    folders: Mapped[list[Folder]] = relationship(
        "Folder", back_populates="user", cascade="all, delete-orphan"
    )
    notes: Mapped[list[Note]] = relationship(
        "Note", back_populates="user", cascade="all, delete-orphan"
    )
