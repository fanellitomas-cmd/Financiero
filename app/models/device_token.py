"""Tabla `device_tokens`: un FCM token por instalación de la app (móvil/web) de un usuario,
para poder despachar push personalizado directo al dispositivo (`send_to_token`) además del
broadcast por tópico/WebSocket que ya hace `PushNotificationService` (ver
`app/services/push_service.py`).
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import DateTime, ForeignKey, String, func
from sqlalchemy import Enum as SAEnum
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.enums import DevicePlatform

if TYPE_CHECKING:
    from app.models.user import User


class DeviceToken(Base):
    __tablename__ = "device_tokens"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    fcm_token: Mapped[str] = mapped_column(
        String(4096), unique=True, nullable=False, index=True
    )
    platform: Mapped[DevicePlatform] = mapped_column(
        SAEnum(DevicePlatform, native_enum=False, length=16), nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    last_seen_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )

    user: Mapped[User] = relationship("User", back_populates="device_tokens")
