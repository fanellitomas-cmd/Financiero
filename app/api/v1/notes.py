"""`/api/v1/notes` — las notas de investigación del Investment Lab.

Todo scopeado a `CurrentUser`. Una nota de otro usuario responde igual que una inexistente (404): un
403 distinguible permitiría enumerar notas ajenas probando UUIDs.
"""

from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, status

from app.api.deps import CurrentUser, NotesServiceDep
from app.schemas.note import NoteCreate, NotePage, NoteRead, NoteUpdate
from app.services.notes_service import FolderNotFoundError, NoteNotFoundError

router = APIRouter(prefix="/notes", tags=["investment-lab"])

_NOTE_NOT_FOUND = HTTPException(
    status_code=status.HTTP_404_NOT_FOUND, detail="Nota no encontrada."
)
_FOLDER_NOT_FOUND = HTTPException(
    status_code=status.HTTP_404_NOT_FOUND,
    detail="La carpeta indicada no existe.",
)


@router.get("", response_model=NotePage, summary="Listar notas")
async def list_notes(
    current_user: CurrentUser,
    notes: NotesServiceDep,
    folder_id: Annotated[
        UUID | None,
        Query(description="Solo las notas archivadas en esta carpeta."),
    ] = None,
    root_only: Annotated[
        bool,
        Query(
            description=(
                "Solo las notas sin carpeta (la raíz del Lab). Tiene prioridad sobre "
                "`folder_id`: son dos preguntas distintas y no se combinan."
            ),
        ),
    ] = False,
    ticker: Annotated[
        str | None,
        Query(
            min_length=1, max_length=20, description="Solo las notas de este símbolo."
        ),
    ] = None,
    q: Annotated[
        str | None,
        Query(
            min_length=1,
            max_length=200,
            description="Búsqueda de texto en el título y en el cuerpo.",
        ),
    ] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> NotePage:
    """Listado paginado, ordenado con las fijadas primero y después por última edición.

    Devuelve resúmenes (título, ticker, excerpt, largo) y NO el cuerpo completo: una carpeta con 50
    tesis serían megabytes por cada apertura de la pantalla, casi todos para texto que no se muestra
    hasta que el usuario abra una nota. El cuerpo se pide con `GET /notes/{id}`.

    `root_only` existe como parámetro aparte porque "las notas sin carpeta" no se puede expresar con
    `folder_id`: omitirlo significa "de cualquier carpeta", y no hay forma de mandar `IS NULL` en un
    query param sin inventar un valor centinela.
    """

    return await notes.list_notes(
        current_user.id,
        folder_id=folder_id,
        root_only=root_only,
        ticker=ticker,
        query=q,
        limit=limit,
        offset=offset,
    )


@router.post(
    "",
    response_model=NoteRead,
    status_code=status.HTTP_201_CREATED,
    summary="Crear una nota",
)
async def create_note(
    payload: NoteCreate, current_user: CurrentUser, notes: NotesServiceDep
) -> NoteRead:
    """Crea una nota, opcionalmente archivada en una carpeta y/o vinculada a un símbolo.

    Los dos vínculos son independientes: una nota de NVDA puede vivir en cualquier carpeta o en
    ninguna, y la Ficha del activo la encuentra igual por `ticker`.
    """

    try:
        return await notes.create_note(current_user.id, payload)
    except FolderNotFoundError as exc:
        raise _FOLDER_NOT_FOUND from exc


@router.get("/{note_id}", response_model=NoteRead, summary="Leer una nota completa")
async def get_note(
    note_id: UUID, current_user: CurrentUser, notes: NotesServiceDep
) -> NoteRead:
    try:
        return await notes.get_note(current_user.id, note_id)
    except NoteNotFoundError as exc:
        raise _NOTE_NOT_FOUND from exc


@router.patch("/{note_id}", response_model=NoteRead, summary="Editar o mover una nota")
async def update_note(
    note_id: UUID,
    payload: NoteUpdate,
    current_user: CurrentUser,
    notes: NotesServiceDep,
) -> NoteRead:
    """PATCH parcial: editar título/cuerpo, fijar, mover de carpeta o cambiar de símbolo.

    Para sacar la nota de su carpeta (o desvincularla del símbolo) hay que mandar `null` EXPLÍCITO —
    omitir el campo significa "no cambiar". Sin esa distinción, una nota archivada no podría volver
    a la raíz.
    """

    try:
        return await notes.update_note(current_user.id, note_id, payload)
    except NoteNotFoundError as exc:
        raise _NOTE_NOT_FOUND from exc
    except FolderNotFoundError as exc:
        raise _FOLDER_NOT_FOUND from exc


@router.delete(
    "/{note_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Eliminar una nota",
)
async def delete_note(
    note_id: UUID, current_user: CurrentUser, notes: NotesServiceDep
) -> None:
    """Borra la nota. Acá sí 204: el resultado es obvio y no arrastra nada más — a diferencia del
    borrado de una carpeta, que reparenta contenido y por eso devuelve un resumen.
    """

    try:
        await notes.delete_note(current_user.id, note_id)
    except NoteNotFoundError as exc:
        raise _NOTE_NOT_FOUND from exc
