"""Schemas de `/api/v1/folders` — el árbol de carpetas del Investment Lab."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class FolderCreate(BaseModel):
    # strict=False (default) deliberado, igual que el resto de los schemas de request: valida JSON
    # externo de un request HTTP, donde UUID llega como string.
    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1, max_length=120)
    parent_id: UUID | None = Field(
        default=None,
        description="Carpeta padre. `null` (u omitido) crea la carpeta en la raíz del Lab.",
    )


class FolderUpdate(BaseModel):
    """PATCH parcial: renombrar, mover, o las dos cosas.

    Mover a la raíz necesita mandar `parent_id: null` explícitamente, y eso choca con "campo
    omitido = no cambiar". Se resuelve con `model_fields_set` en el servicio: se distingue "no vino"
    de "vino en null" mirando qué claves trajo el request, no el valor. Sin eso, mover una
    subcarpeta a la raíz sería imposible de expresar.
    """

    model_config = ConfigDict(extra="forbid")

    name: str | None = Field(default=None, min_length=1, max_length=120)
    parent_id: UUID | None = None


class FolderRead(BaseModel):
    """Una carpeta con lo que la UI necesita para pintar el árbol sin recalcularlo.

    `depth` y `path` los computa el backend: el cliente recibe una lista PLANA ya ordenada por
    `path`, así que puede renderizar la jerarquía recorriéndola una vez e indentando por `depth`.
    Se eligió lista plana y no JSON anidado porque el anidado obliga a recorrer recursivamente para
    cualquier operación (buscar una carpeta, contar notas, mover) y no se puede paginar ni comparar
    entre dos respuestas.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    id: UUID
    name: str
    parent_id: UUID | None
    created_at: datetime
    updated_at: datetime

    # Profundidad en el árbol: 0 para las carpetas de la raíz.
    depth: int = Field(ge=0)

    # Ruta legible completa ("Research / Semiconductores / NVDA"). Sirve para el breadcrumb y para
    # ordenar: dos carpetas hermanas quedan juntas y sus hijas debajo, sin trabajo del cliente.
    path: str

    # Notas directamente en esta carpeta (no incluye las de sus subcarpetas). Es lo que la UI
    # muestra al lado del nombre, y contarlo del lado del servidor evita que el cliente pida las
    # notas de cada carpeta solo para saber cuántas hay.
    note_count: int = Field(ge=0)
    subfolder_count: int = Field(ge=0)


class FolderDeletionResult(BaseModel):
    """Qué pasó al borrar una carpeta.

    Un DELETE que devuelve 204 sería la convención, pero acá el resultado NO es obvio: por defecto
    las notas de adentro sobreviven y se mueven a la raíz, y las subcarpetas suben un nivel. Un
    usuario que borró "Research" y esperaba perder todo necesita ver que sus 12 notas siguen
    estando; y uno que pidió cascada necesita ver cuánto se borró. Devolver el resumen convierte una
    sorpresa en información.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    deleted_folder_id: UUID
    cascade: bool

    # Con `cascade=False`: subcarpetas que subieron un nivel y notas que quedaron en la raíz.
    reparented_folders: int = Field(default=0, ge=0)
    detached_notes: int = Field(default=0, ge=0)

    # Con `cascade=True`: cuántas carpetas y notas del subárbol se borraron (sin contar la carpeta
    # pedida, que va aparte en `deleted_folder_id`).
    deleted_folders: int = Field(default=0, ge=0)
    deleted_notes: int = Field(default=0, ge=0)
