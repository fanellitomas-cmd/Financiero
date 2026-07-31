"""Tabla `alert_history`. `urgency_level` reutiliza `AlertSeverity` del motor (`src/`) — ya
tiene exactamente LOW/MEDIUM/HIGH/CRITICAL, no hace falta duplicarlo en la capa de producto.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import JSON, DateTime, String, func
from sqlalchemy import Enum as SAEnum
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base
from src.validation.domain_models import AlertSeverity


class AlertHistory(Base):
    __tablename__ = "alert_history"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    ticker: Mapped[str] = mapped_column(String(20), nullable=False, index=True)
    payload_json: Mapped[dict[str, object]] = mapped_column(JSON, nullable=False)
    urgency_level: Mapped[AlertSeverity] = mapped_column(
        SAEnum(AlertSeverity, native_enum=False, length=16), nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False, index=True
    )
