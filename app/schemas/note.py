"""Schemas de `/api/v1/notes` — las notas de investigación del Investment Lab."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

# Tope del cuerpo de una nota. Es generoso a propósito (unas 30 páginas de texto) porque el módulo
# existe justamente para escribir tesis largas, pero existe: sin tope, un cliente con un bug puede
# empujar megabytes en una fila y el error aparecería recién en el driver, sin un 422 legible.
_MAX_CONTENT_LENGTH = 60_000


class NoteCreate(BaseModel):
    # strict=False (default) deliberado, igual que el resto de los schemas de request.
    model_config = ConfigDict(extra="forbid")

    title: str = Field(min_length=1, max_length=200)
    content: str = Field(default="", max_length=_MAX_CONTENT_LENGTH)
    folder_id: UUID | None = Field(
        default=None,
        description="Carpeta donde archivarla. `null` (u omitido) la deja en la raíz del Lab.",
    )
    ticker: str | None = Field(
        default=None,
        min_length=1,
        max_length=20,
        description=(
            "Símbolo al que la nota se refiere. Independiente de la carpeta: una nota de NVDA "
            "puede vivir en cualquier carpeta o en ninguna."
        ),
    )
    pinned: bool = False


class NoteUpdate(BaseModel):
    """PATCH parcial: editar, mover de carpeta, cambiar de ticker, fijar.

    Igual que `FolderUpdate`, "sacar de la carpeta" y "desvincular del ticker" se expresan mandando
    `null` explícito, y el servicio distingue eso de "campo omitido" con `model_fields_set`. Sin esa
    distinción, una nota archivada no podría volver a la raíz.
    """

    model_config = ConfigDict(extra="forbid")

    title: str | None = Field(default=None, min_length=1, max_length=200)
    content: str | None = Field(default=None, max_length=_MAX_CONTENT_LENGTH)
    folder_id: UUID | None = None
    ticker: str | None = Field(default=None, min_length=1, max_length=20)
    pinned: bool | None = None


class NoteRead(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", from_attributes=True)

    id: UUID
    folder_id: UUID | None
    ticker: str | None
    title: str
    content: str
    pinned: bool
    created_at: datetime
    updated_at: datetime


class NoteSummary(BaseModel):
    """Una nota SIN su cuerpo, para los listados.

    El listado devuelve resúmenes y no notas completas porque el cuerpo puede tener decenas de miles
    de caracteres: una carpeta con 50 tesis serían megabytes por cada apertura de la pantalla, casi
    todos para texto que no se va a mostrar hasta que el usuario abra una.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    id: UUID
    folder_id: UUID | None
    ticker: str | None
    title: str
    pinned: bool
    created_at: datetime
    updated_at: datetime

    # Primeras líneas del cuerpo, para la vista previa de la lista.
    excerpt: str

    # Largo real del cuerpo. Deja que la UI distinga una nota vacía de una larga sin traérsela — y
    # que el `excerpt` no tenga que llevar un "…" ambiguo.
    content_length: int = Field(ge=0)


class NotePage(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    items: list[NoteSummary]
    total: int = Field(ge=0)
    limit: int = Field(ge=1)
    offset: int = Field(ge=0)
