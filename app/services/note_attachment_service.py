"""Servicio de adjuntos de nota: capturas de gráficos y su capa de dibujo.

Separado de `NotesService` aunque comparta el módulo del Lab, porque lo que maneja es distinto: acá
hay blobs. Las tres reglas que se derivan de eso y que el resto del Lab no necesita:

  1. **Los bytes no se cargan salvo que se pidan.** `NoteAttachment.image_bytes` es `deferred`, así
     que listar es barato; el único camino que la trae es [NoteAttachmentService.load_image], y es
     explícito justamente para que agregarla a otra consulta sea una decisión visible.
  2. **La imagen es inmutable, el dibujo no.** Actualizar una anotación reescribe unos cientos de
     bytes de JSON y no toca el blob. Volver a capturar el gráfico es subir un adjunto nuevo.
  3. **Todo está scopeado al usuario Y a la nota.** Un adjunto de otro usuario, o de otra nota del
     mismo usuario, responde igual que uno inexistente: un 403 distinguible permitiría enumerar
     capturas ajenas probando UUIDs, y un adjunto que se puede leer desde la nota equivocada rompe la
     promesa de que la nota es la unidad de organización.
"""

from __future__ import annotations

import logging
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
from sqlalchemy.orm import undefer

from app.models.note import Note
from app.models.note_attachment import NoteAttachment
from app.schemas.note_attachment import (
    DrawingLayer,
    NoteAttachmentCreate,
    NoteAttachmentRead,
    NoteAttachmentUpdate,
)

logger = logging.getLogger(__name__)

# Tope de adjuntos por nota. Existe por la misma razón que el tope de profundidad de las carpetas: un
# cliente con un bug puede subir en bucle, y el costo acá se mide en megabytes de tabla.
MAX_ATTACHMENTS_PER_NOTE = 40


class NoteNotFoundError(Exception):
    """La nota no existe o es de otro usuario."""


class AttachmentNotFoundError(Exception):
    """El adjunto no existe, es de otro usuario, o pertenece a otra nota."""


class TooManyAttachmentsError(Exception):
    """La nota llegó al tope de adjuntos."""


def _image_url(note_id: UUID, attachment_id: UUID) -> str:
    return f"/api/v1/notes/{note_id}/attachments/{attachment_id}/image"


def _to_read(attachment: NoteAttachment) -> NoteAttachmentRead:
    """Convierte la fila en su representación pública.

    El `drawing_data` se revalida al leerlo, no solo al escribirlo: la columna es JSON libre a nivel
    de base, así que una fila escrita por una versión anterior (o tocada a mano) podría no cumplir el
    contrato actual. Si no valida, se devuelve una capa VACÍA en vez de propagar el error — la
    captura sigue siendo útil sin sus anotaciones, y un 500 dejaría la nota entera inaccesible por un
    dibujo roto.
    """

    try:
        drawing = DrawingLayer.model_validate(attachment.drawing_data)
    except ValueError:
        logger.warning(
            "note_attachment_drawing_invalid",
            extra={"attachment_id": str(attachment.id)},
        )
        drawing = DrawingLayer()

    return NoteAttachmentRead(
        id=attachment.id,
        note_id=attachment.note_id,
        ticker=attachment.ticker,
        content_type=attachment.content_type,
        byte_size=attachment.byte_size,
        width=attachment.width,
        height=attachment.height,
        caption=attachment.caption,
        source=attachment.source,
        drawing=drawing,
        image_url=_image_url(attachment.note_id, attachment.id),
        created_at=attachment.created_at,
        updated_at=attachment.updated_at,
    )


class NoteAttachmentService:
    def __init__(self, session_factory: async_sessionmaker[AsyncSession]) -> None:
        self._session_factory = session_factory

    async def list_attachments(
        self, user_id: UUID, note_id: UUID
    ) -> list[NoteAttachmentRead]:
        async with self._session_factory() as session:
            await self._require_note(session, user_id, note_id)
            rows = await session.scalars(
                select(NoteAttachment)
                .where(
                    NoteAttachment.user_id == user_id,
                    NoteAttachment.note_id == note_id,
                )
                # Orden de subida: es el orden en que el usuario armó la secuencia de capturas, y
                # ordenar por última edición las reordenaría cada vez que retoca una anotación.
                .order_by(NoteAttachment.created_at)
            )
            return [_to_read(row) for row in rows.all()]

    async def create(
        self, user_id: UUID, note_id: UUID, payload: NoteAttachmentCreate
    ) -> NoteAttachmentRead:
        image = payload.image

        async with self._session_factory() as session:
            await self._require_note(session, user_id, note_id)

            existing = await session.scalar(
                select(func.count())
                .select_from(NoteAttachment)
                .where(
                    NoteAttachment.user_id == user_id,
                    NoteAttachment.note_id == note_id,
                )
            )
            if (existing or 0) >= MAX_ATTACHMENTS_PER_NOTE:
                raise TooManyAttachmentsError(str(MAX_ATTACHMENTS_PER_NOTE))

            attachment = NoteAttachment(
                note_id=note_id,
                user_id=user_id,
                ticker=payload.ticker,
                image_bytes=image,
                content_type=payload.content_type,
                byte_size=len(image),
                width=payload.width,
                height=payload.height,
                caption=payload.caption,
                source=payload.source,
                drawing_data=payload.drawing.model_dump(mode="json"),
            )
            session.add(attachment)
            await session.commit()
            await session.refresh(attachment)
            return _to_read(attachment)

    async def update(
        self,
        user_id: UUID,
        note_id: UUID,
        attachment_id: UUID,
        payload: NoteAttachmentUpdate,
    ) -> NoteAttachmentRead:
        """Reemplaza la capa de dibujo completa.

        NO toca `image_bytes`: la captura es la misma, cambió lo que el usuario trazó encima. Es lo
        que hace barato editar una anotación sobre una imagen de 800 KB.
        """

        async with self._session_factory() as session:
            attachment = await self._require_attachment(
                session, user_id, note_id, attachment_id
            )

            attachment.drawing_data = payload.drawing.model_dump(mode="json")
            # `caption` y `ticker` siguen la convención del resto del Lab: la clave presente en `null`
            # los desvincula. Como `NoteAttachmentUpdate` los declara opcionales con default `None`,
            # se mira `model_fields_set` para distinguir "no vino" de "vino vacío".
            provided = payload.model_fields_set
            if "caption" in provided:
                attachment.caption = payload.caption
            if "ticker" in provided:
                attachment.ticker = payload.ticker

            await session.commit()
            await session.refresh(attachment)
            return _to_read(attachment)

    async def delete(self, user_id: UUID, note_id: UUID, attachment_id: UUID) -> None:
        async with self._session_factory() as session:
            attachment = await self._require_attachment(
                session, user_id, note_id, attachment_id
            )
            await session.delete(attachment)
            await session.commit()

    async def load_image(
        self, user_id: UUID, note_id: UUID, attachment_id: UUID
    ) -> tuple[bytes, str]:
        """Los bytes crudos y su `Content-Type`.

        Es el ÚNICO camino que trae la columna `deferred`, y por eso el `undefer` va explícito: si
        alguna otra consulta empezara a cargarla sin querer, el listado dejaría de ser barato sin que
        nada falle.
        """

        async with self._session_factory() as session:
            attachment = await session.scalar(
                select(NoteAttachment)
                .options(undefer(NoteAttachment.image_bytes))
                .where(
                    NoteAttachment.id == attachment_id,
                    NoteAttachment.note_id == note_id,
                    NoteAttachment.user_id == user_id,
                )
            )
            if attachment is None:
                raise AttachmentNotFoundError(str(attachment_id))
            return attachment.image_bytes, attachment.content_type

    # --- Internos ---------------------------------------------------------------------------

    async def _require_note(
        self, session: AsyncSession, user_id: UUID, note_id: UUID
    ) -> Note:
        note = await session.scalar(
            select(Note).where(Note.id == note_id, Note.user_id == user_id)
        )
        if note is None:
            raise NoteNotFoundError(str(note_id))
        return note

    async def _require_attachment(
        self,
        session: AsyncSession,
        user_id: UUID,
        note_id: UUID,
        attachment_id: UUID,
    ) -> NoteAttachment:
        """Carga el adjunto exigiendo las TRES condiciones: id, nota y dueño.

        Filtrar también por `note_id` no es redundante con el `user_id`: sin eso, un adjunto propio se
        podría leer y editar desde la URL de cualquier otra nota propia, y el `note_id` de la ruta
        pasaría a ser decorativo.
        """

        attachment = await session.scalar(
            select(NoteAttachment).where(
                NoteAttachment.id == attachment_id,
                NoteAttachment.note_id == note_id,
                NoteAttachment.user_id == user_id,
            )
        )
        if attachment is None:
            raise AttachmentNotFoundError(str(attachment_id))
        return attachment
