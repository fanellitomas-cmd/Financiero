"""Tabla `folders`: el árbol de carpetas del Investment Lab, donde el usuario organiza sus notas
de investigación.

Autoreferencial (`parent_id`) para permitir subcarpetas. Dos invariantes que el esquema NO puede
garantizar solo y que la capa de servicio sostiene explícitamente (ver
`app/services/notes_service.py`):

  1. **Sin ciclos.** La base acepta perfectamente A -> B -> A: la FK solo exige que el padre
     exista. Un ciclo desaparece del árbol (ninguna de sus carpetas cuelga de la raíz) y se lleva
     las notas de adentro con él, así que el chequeo al mover es obligatorio.
  2. **Sin nombres duplicados entre hermanas.** Dos carpetas "Research" con el mismo padre son
     indistinguibles en la UI. Una `UniqueConstraint(user_id, parent_id, name)` no alcanza: en SQL
     dos NULL son distintos, así que las carpetas de raíz (`parent_id IS NULL`) quedarían fuera del
     constraint y la regla valdría para las subcarpetas y no para el primer nivel. Se valida en la
     aplicación para que signifique lo mismo en los dos casos.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import DateTime, ForeignKey, String, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base

if TYPE_CHECKING:
    from app.models.note import Note
    from app.models.user import User


class Folder(Base):
    __tablename__ = "folders"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    name: Mapped[str] = mapped_column(String(120), nullable=False)

    # `ondelete="SET NULL"` y no CASCADE: borrar una carpeta NO puede llevarse su subárbol por
    # decisión de la base. La política de borrado la decide el servicio (reparentar por defecto,
    # cascada solo si el usuario la pide explícitamente), y un CASCADE acá haría que un DELETE
    # directo en SQL destruyera notas sin pasar por esa decisión.
    parent_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("folders.id", ondelete="SET NULL"), nullable=True, index=True
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

    user: Mapped[User] = relationship("User", back_populates="folders")

    # `remote_side` es imprescindible en una relación autoreferencial: sin él SQLAlchemy no puede
    # saber cuál de los dos lados de `folders.parent_id -> folders.id` es el "uno" y cuál el
    # "muchos", y falla al configurar el mapper.
    parent: Mapped[Folder | None] = relationship(
        "Folder", remote_side=[id], back_populates="children"
    )
    children: Mapped[list[Folder]] = relationship(
        "Folder", back_populates="parent", cascade="save-update"
    )

    # Sin `cascade="all, delete-orphan"`: las notas sobreviven al borrado de su carpeta (pasan a la
    # raíz). Es la decisión de producto central del módulo — ver `NotesService.delete_folder`.
    notes: Mapped[list[Note]] = relationship("Note", back_populates="folder")
