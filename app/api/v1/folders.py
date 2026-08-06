"""`/api/v1/folders` — el árbol de carpetas del Investment Lab.

Todo scopeado a `CurrentUser`: nunca se lee, mueve ni borra una carpeta de otro usuario, aunque se
conozca su UUID.
"""

from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, status

from app.api.deps import CurrentUser, NotesServiceDep
from app.schemas.folder import (
    FolderCreate,
    FolderDeletionResult,
    FolderRead,
    FolderUpdate,
)
from app.services.notes_service import (
    MAX_FOLDER_DEPTH,
    DuplicateFolderNameError,
    FolderCycleError,
    FolderDepthExceededError,
    FolderNotFoundError,
)

router = APIRouter(prefix="/folders", tags=["investment-lab"])

_FOLDER_NOT_FOUND = HTTPException(
    status_code=status.HTTP_404_NOT_FOUND, detail="Carpeta no encontrada."
)


@router.get("", response_model=list[FolderRead], summary="Árbol de carpetas")
async def list_folders(
    current_user: CurrentUser, notes: NotesServiceDep
) -> list[FolderRead]:
    """Devuelve el árbol como lista PLANA ya ordenada por ruta, con `depth` y `path` calculados.

    Lista y no JSON anidado a propósito: el cliente la recorre una vez e indenta por `depth`, y a
    cambio puede buscar, comparar y paginar sin recursión. Un árbol anidado obliga a recorrer
    recursivamente para cualquier operación y no se puede diffear entre dos respuestas.

    Cada entrada trae además `note_count` (notas directamente en ella) y `subfolder_count`, para que
    la UI no tenga que pedir las notas de cada carpeta solo para saber cuántas hay.
    """

    return await notes.list_folders(current_user.id)


@router.post(
    "",
    response_model=FolderRead,
    status_code=status.HTTP_201_CREATED,
    summary="Crear una carpeta",
)
async def create_folder(
    payload: FolderCreate, current_user: CurrentUser, notes: NotesServiceDep
) -> FolderRead:
    """Crea una carpeta en la raíz (`parent_id` omitido o `null`) o dentro de otra.

    Rechaza con 409 un nombre ya usado por una hermana: dos "Research" en el mismo nivel son
    indistinguibles al mover una nota.
    """

    try:
        return await notes.create_folder(current_user.id, payload)
    except FolderNotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="La carpeta padre no existe.",
        ) from exc
    except DuplicateFolderNameError as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Ya tenés una carpeta llamada «{exc}» en ese nivel.",
        ) from exc
    except FolderDepthExceededError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail=(
                f"No se pueden anidar más de {MAX_FOLDER_DEPTH} niveles de carpetas."
            ),
        ) from exc


@router.patch(
    "/{folder_id}",
    response_model=FolderRead,
    summary="Renombrar o mover una carpeta",
)
async def update_folder(
    folder_id: UUID,
    payload: FolderUpdate,
    current_user: CurrentUser,
    notes: NotesServiceDep,
) -> FolderRead:
    """PATCH parcial: `name` renombra, `parent_id` mueve, y se pueden mandar los dos.

    Para mover una carpeta a la raíz hay que mandar `parent_id: null` EXPLÍCITO — omitir el campo
    significa "dejarla donde está", y sin esa distinción sacar una subcarpeta de su padre sería
    imposible de expresir.

    Rechaza con 422 un movimiento que haría a la carpeta su propia ancestra: la base aceptaría ese
    `UPDATE` sin problema y el subárbol resultante desaparecería del listado, llevándose las notas
    de adentro.
    """

    try:
        return await notes.update_folder(current_user.id, folder_id, payload)
    except FolderNotFoundError as exc:
        raise _FOLDER_NOT_FOUND from exc
    except DuplicateFolderNameError as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Ya tenés una carpeta llamada «{exc}» en ese nivel.",
        ) from exc
    except FolderCycleError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail=(
                "No se puede mover una carpeta dentro de sí misma ni de una de sus "
                "subcarpetas."
            ),
        ) from exc
    except FolderDepthExceededError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail=(
                f"El movimiento pasaría el límite de {MAX_FOLDER_DEPTH} niveles de "
                "carpetas."
            ),
        ) from exc


@router.delete(
    "/{folder_id}",
    response_model=FolderDeletionResult,
    summary="Eliminar una carpeta",
)
async def delete_folder(
    folder_id: UUID,
    current_user: CurrentUser,
    notes: NotesServiceDep,
    cascade: Annotated[
        bool,
        Query(
            description=(
                "`false` (default): las notas de la carpeta pasan a la raíz y las subcarpetas "
                "suben un nivel — no se pierde nada. `true`: borra el subárbol completo con sus "
                "notas."
            ),
        ),
    ] = False,
) -> FolderDeletionResult:
    """Elimina una carpeta. **Por defecto no se pierde ninguna nota.**

    Devuelve 200 con un resumen en vez de 204 porque el resultado no es obvio: quien borró
    "Research" esperando perder todo necesita ver que sus notas siguen estando (y dónde), y quien
    pidió cascada necesita ver cuánto se borró. Un 204 mudo convertiría eso en una sorpresa.
    """

    try:
        return await notes.delete_folder(current_user.id, folder_id, cascade=cascade)
    except FolderNotFoundError as exc:
        raise _FOLDER_NOT_FOUND from exc
