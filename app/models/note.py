"""Tabla `notes`: las notas de investigación del Investment Lab.

`folder_id` y `ticker` son los dos ejes de organización y son INDEPENDIENTES a propósito: una nota
sobre NVDA puede vivir en la carpeta "Semiconductores" o en ninguna, y la Ficha de un activo quiere
mostrar todas sus notas sin importar dónde estén archivadas. Forzar que una nota vinculada a un
ticker viva en una carpeta del ticker haría que las dos vistas peleen por la misma jerarquía.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import Boolean, DateTime, ForeignKey, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base

if TYPE_CHECKING:
    from app.models.folder import Folder
    from app.models.note_attachment import NoteAttachment
    from app.models.user import User


class Note(Base):
    __tablename__ = "notes"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )

    # `SET NULL` y nullable: una nota sin carpeta es un estado normal (la raíz del Lab), no un
    # error. Y es a dónde van las notas cuando su carpeta se borra sin cascada, así que la base
    # tiene que aceptarlo — un `ondelete="CASCADE"` acá convertiría "borré una carpeta" en "perdí
    # las notas".
    folder_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("folders.id", ondelete="SET NULL"), nullable=True, index=True
    )

    # Símbolo del activo al que la nota se refiere, normalizado a mayúsculas por el servicio.
    # Indexado porque la consulta "todas mis notas de NVDA" es el acceso más frecuente después del
    # listado por carpeta. NO es una FK al catálogo `tickers`: se puede tomar nota sobre una cripto
    # o sobre un símbolo que todavía no se sincronizó, y una FK volvería inusable el módulo con el
    # catálogo vacío.
    ticker: Mapped[str | None] = mapped_column(String(20), nullable=True, index=True)

    title: Mapped[str] = mapped_column(String(200), nullable=False)

    # `Text` y no `String(n)`: es markdown escrito por el usuario y no hay un largo natural. El
    # tope real lo pone el schema de request (`app/schemas/note.py`), que es donde se puede
    # rechazar con un 422 legible en vez de un error del driver.
    content: Mapped[str] = mapped_column(Text, nullable=False, default="")

    pinned: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )

    user: Mapped[User] = relationship("User", back_populates="notes")
    folder: Mapped[Folder | None] = relationship("Folder", back_populates="notes")

    # Acá SÍ va `delete-orphan`, al revés que en `Folder.notes`: un adjunto no significa nada sin su
    # nota y no hay a dónde reparentarlo. El cascade se declara a nivel ORM y no solo con el
    # `ondelete` de la FK porque SQLite ignora las acciones referenciales salvo que se prenda
    # `PRAGMA foreign_keys`, y el entorno de tests corre sobre SQLite.
    attachments: Mapped[list[NoteAttachment]] = relationship(
        "NoteAttachment",
        back_populates="note",
        cascade="all, delete-orphan",
        order_by="NoteAttachment.created_at",
    )
