"""`/api/v1/notes/{note_id}/attachments` — capturas de gráficos anotadas del Investment Lab.

Todo scopeado a `CurrentUser` y a la nota de la ruta: un adjunto de otro usuario, o de otra nota,
responde 404 igual que uno inexistente.
"""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, HTTPException, Response, status

from app.api.deps import AttachmentsServiceDep, CurrentUser
from app.schemas.note_attachment import (
    NoteAttachmentCreate,
    NoteAttachmentRead,
    NoteAttachmentUpdate,
)
from app.services.note_attachment_service import (
    MAX_ATTACHMENTS_PER_NOTE,
    AttachmentNotFoundError,
    NoteNotFoundError,
    TooManyAttachmentsError,
)

router = APIRouter(prefix="/notes", tags=["investment-lab"])

_NOTE_NOT_FOUND = HTTPException(
    status_code=status.HTTP_404_NOT_FOUND, detail="Nota no encontrada."
)
_ATTACHMENT_NOT_FOUND = HTTPException(
    status_code=status.HTTP_404_NOT_FOUND, detail="Adjunto no encontrado."
)


@router.get(
    "/{note_id}/attachments",
    response_model=list[NoteAttachmentRead],
    summary="Capturas adjuntas a una nota",
)
async def list_attachments(
    note_id: UUID, current_user: CurrentUser, attachments: AttachmentsServiceDep
) -> list[NoteAttachmentRead]:
    """Los adjuntos con sus metadatos y su capa de dibujo, SIN los bytes de la imagen.

    Cada entrada trae `image_url`, que es de donde se bajan los píxeles. Devolverlos acá en base64
    haría que abrir una nota con diez capturas transfiera decenas de megabytes en cada apertura, casi
    todos para imágenes que el navegador ya tiene cacheadas por URL.
    """

    try:
        return await attachments.list_attachments(current_user.id, note_id)
    except NoteNotFoundError as exc:
        raise _NOTE_NOT_FOUND from exc


@router.post(
    "/{note_id}/attachments",
    response_model=NoteAttachmentRead,
    status_code=status.HTTP_201_CREATED,
    summary="Adjuntar una captura de gráfico",
)
async def create_attachment(
    note_id: UUID,
    payload: NoteAttachmentCreate,
    current_user: CurrentUser,
    attachments: AttachmentsServiceDep,
) -> NoteAttachmentRead:
    """Sube una imagen (base64) junto con su capa de trazado vectorial.

    Las dos cosas van en el MISMO request porque una captura pegada sin sus anotaciones, aunque sea
    por un instante, es un estado que el usuario nunca pidió: si la segunda llamada fallara, quedaría
    una imagen sin las marcas que le dan sentido.

    El dibujo puede venir vacío: pegar primero y anotar después es el flujo normal.
    """

    try:
        return await attachments.create(current_user.id, note_id, payload)
    except NoteNotFoundError as exc:
        raise _NOTE_NOT_FOUND from exc
    except TooManyAttachmentsError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail=(
                f"Una nota no puede tener más de {MAX_ATTACHMENTS_PER_NOTE} capturas. "
                "Borrá alguna o creá una nota nueva."
            ),
        ) from exc


@router.get(
    "/{note_id}/attachments/{attachment_id}/image",
    summary="Bytes de una captura",
    response_class=Response,
    responses={
        200: {"content": {"image/png": {}}, "description": "La imagen."},
        404: {"description": "El adjunto no existe o no es del usuario."},
    },
)
async def get_attachment_image(
    note_id: UUID,
    attachment_id: UUID,
    current_user: CurrentUser,
    attachments: AttachmentsServiceDep,
) -> Response:
    """Devuelve la imagen cruda.

    Endpoint aparte del listado, y autenticado como todo el resto: las capturas de la cartera de
    alguien son tan privadas como sus notas, así que no se sirven desde una ruta estática adivinable.

    Se cachea de forma privada y por mucho tiempo porque el contenido es **inmutable**: editar las
    anotaciones no cambia estos bytes (eso vive en `drawing_data`), y volver a capturar el gráfico
    crea un adjunto nuevo con otra URL.
    """

    try:
        image, content_type = await attachments.load_image(
            current_user.id, note_id, attachment_id
        )
    except AttachmentNotFoundError as exc:
        raise _ATTACHMENT_NOT_FOUND from exc

    return Response(
        content=image,
        media_type=content_type,
        headers={"Cache-Control": "private, max-age=31536000, immutable"},
    )


@router.put(
    "/{note_id}/attachments/{attachment_id}",
    response_model=NoteAttachmentRead,
    summary="Guardar la capa de dibujo de una captura",
)
async def update_attachment(
    note_id: UUID,
    attachment_id: UUID,
    payload: NoteAttachmentUpdate,
    current_user: CurrentUser,
    attachments: AttachmentsServiceDep,
) -> NoteAttachmentRead:
    """Reemplaza las anotaciones de la captura.

    PUT y no PATCH a propósito: el canvas conoce su estado completo y lo manda entero. Un protocolo
    de parches por forma necesitaría resolver conflictos para un recurso que edita un solo usuario en
    una sola pantalla, y dejaría sin forma de expresar "borré esta línea".

    La imagen no se toca. Editar una flecha sobre una captura de 800 KB reescribe unos cientos de
    bytes de JSON.
    """

    try:
        return await attachments.update(
            current_user.id, note_id, attachment_id, payload
        )
    except AttachmentNotFoundError as exc:
        raise _ATTACHMENT_NOT_FOUND from exc


@router.delete(
    "/{note_id}/attachments/{attachment_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Eliminar una captura adjunta",
)
async def delete_attachment(
    note_id: UUID,
    attachment_id: UUID,
    current_user: CurrentUser,
    attachments: AttachmentsServiceDep,
) -> None:
    """Borra la captura y su capa de dibujo. 204: el resultado es obvio y no arrastra nada más — a
    diferencia del borrado de una carpeta, que reparenta contenido y por eso devuelve un resumen.
    """

    try:
        await attachments.delete(current_user.id, note_id, attachment_id)
    except AttachmentNotFoundError as exc:
        raise _ATTACHMENT_NOT_FOUND from exc
