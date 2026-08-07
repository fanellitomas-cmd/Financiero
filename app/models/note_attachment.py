"""Tabla `note_attachments`: capturas de gráficos adjuntas a una nota, con su capa de dibujo.

Dos datos por adjunto y con ciclos de vida distintos:

  1. **La imagen** (`image_bytes`): el píxel de la captura. No cambia nunca después de subida — una
     captura anotada sigue siendo la misma captura.
  2. **La capa de dibujo** (`drawing_data`): las líneas, rectángulos y textos que el usuario trazó
     encima. Es vectorial y se reescribe cada vez que edita el canvas.

Se guardan separados a propósito y NO se "quema" el dibujo dentro del PNG: quemarlo haría que borrar
una línea obligue a volver a capturar el gráfico, y perdería para siempre la posibilidad de mover una
anotación. Además el dibujo pesa unos cientos de bytes contra los cientos de KB de la imagen, así que
editarlo no reescribe el blob.

**Los bytes viven en la base y no en el disco.** Es una decisión consciente: el proyecto no tiene
almacenamiento de objetos configurado, y un directorio de archivos agregaría un estado que hay que
montar como volumen, respaldar aparte y limpiar a mano cuando un borrado falla a la mitad. Con los
bytes en la fila, borrar la nota borra la imagen en la misma transacción y no quedan huérfanos. El
costo —una tabla grande— se acota con el tope de tamaño del schema y con `deferred`: la columna NO se
carga salvo que se pida explícitamente, así que listar los adjuntos de una nota no baja un solo byte
de imagen.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import JSON, DateTime, ForeignKey, Integer, LargeBinary, String, func
from sqlalchemy.orm import Mapped, deferred, mapped_column, relationship

from app.core.database import Base

if TYPE_CHECKING:
    from app.models.note import Note
    from app.models.user import User


class NoteAttachment(Base):
    __tablename__ = "note_attachments"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)

    # `CASCADE` acá SÍ es lo correcto, al revés que en `folders`: un adjunto no significa nada sin su
    # nota y no hay ningún lugar razonable al que reparentarlo. Borrar la nota se lo lleva.
    note_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("notes.id", ondelete="CASCADE"), nullable=False, index=True
    )

    # Se desnormaliza el dueño en la fila del adjunto. Sin esto, cada lectura tendría que hacer un
    # JOIN con `notes` solo para chequear a quién pertenece, y la consulta de autorización es la que
    # corre en TODOS los endpoints del módulo.
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )

    # Símbolo del gráfico capturado. Independiente del `ticker` de la nota: una nota comparativa
    # sobre el sector puede tener adjuntos de NVDA y de AMD.
    ticker: Mapped[str | None] = mapped_column(String(20), nullable=True, index=True)

    # Los bytes crudos de la imagen, NO su base64: el cliente la manda codificada porque el cuerpo es
    # JSON, pero guardarla así desperdiciaría un 33% del espacio para siempre.
    #
    # `deferred`: la columna no se trae salvo que se pida. Es lo que hace que listar los adjuntos de
    # una nota sea barato — sin esto, abrir una nota con diez capturas bajaría varios megabytes para
    # dibujar diez miniaturas.
    image_bytes: Mapped[bytes] = deferred(mapped_column(LargeBinary, nullable=False))

    content_type: Mapped[str] = mapped_column(String(64), nullable=False)

    # Tamaño en bytes, guardado aparte de la imagen justamente porque la imagen es `deferred`: el
    # listado necesita poder decir "820 KB" sin traerse los 820 KB.
    byte_size: Mapped[int] = mapped_column(Integer, nullable=False)

    # Dimensiones en píxeles, si el cliente las declaró. Sirven para reservar el espacio del canvas
    # antes de que la imagen termine de bajar, y para convertir las coordenadas normalizadas del
    # dibujo a píxeles al exportar.
    width: Mapped[int | None] = mapped_column(Integer, nullable=True)
    height: Mapped[int | None] = mapped_column(Integer, nullable=True)

    caption: Mapped[str | None] = mapped_column(String(300), nullable=True)

    # De dónde salió la captura (el chart de la app, un archivo del usuario…). Es metadato, no
    # contrato: se guarda como texto libre acotado.
    source: Mapped[str | None] = mapped_column(String(64), nullable=True)

    # La capa vectorial. `JSON` y no una tabla de formas: se lee y se reescribe SIEMPRE entera (el
    # canvas manda su estado completo), nunca se consulta por forma, y normalizarla obligaría a un
    # DELETE + INSERT masivo en cada trazo.
    drawing_data: Mapped[dict[str, object]] = mapped_column(JSON, nullable=False)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )

    note: Mapped[Note] = relationship("Note", back_populates="attachments")
    user: Mapped[User] = relationship("User", back_populates="note_attachments")
