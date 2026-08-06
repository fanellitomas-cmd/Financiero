"""Servicio del Investment Lab: carpetas y notas de investigación del usuario.

Un solo servicio para las dos entidades y no uno por tabla, porque la decisión más importante del
módulo las cruza: **borrar una carpeta no borra las notas de adentro**. Separarlos dejaría esa
política repartida entre dos archivos que tendrían que coordinarse.

Las tres reglas que sostienen la integridad del árbol, ninguna de las cuales el esquema puede
garantizar sola:

  1. **Sin ciclos.** Mover A dentro de su propio descendiente es un `UPDATE` perfectamente válido
     para la base, y produce un subárbol huérfano que desaparece de la vista (ninguna de sus
     carpetas cuelga de la raíz) llevándose las notas de adentro. Se chequea recorriendo la cadena
     de ancestros antes de mover.
  2. **Profundidad acotada.** Sin tope, un cliente con un bug puede armar una cadena de cientos de
     niveles que ninguna UI puede mostrar y que vuelve caro cada cálculo de `path`.
  3. **Sin hermanas homónimas.** Dos "Research" con el mismo padre son indistinguibles al mover una
     nota. Se valida en la aplicación y no con un `UniqueConstraint` porque en SQL dos NULL son
     distintos: el constraint dejaría afuera justamente a las carpetas de la raíz.

Todo scopeado al usuario autenticado: las consultas filtran por `user_id` SIEMPRE, y una carpeta o
nota de otro usuario responde igual que una inexistente (un 403 distinguible permitiría enumerar
recursos ajenos probando UUIDs).
"""

from __future__ import annotations

import logging
from uuid import UUID

from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.folder import Folder
from app.models.note import Note
from app.schemas.folder import (
    FolderCreate,
    FolderDeletionResult,
    FolderRead,
    FolderUpdate,
)
from app.schemas.note import NoteCreate, NotePage, NoteRead, NoteSummary, NoteUpdate

logger = logging.getLogger(__name__)

# Profundidad máxima del árbol (0 = raíz). Ocho niveles son más de lo que cualquier organización
# real necesita y mucho menos de lo que rompe la UI o el cálculo de rutas.
MAX_FOLDER_DEPTH = 8

# Separador de la ruta legible. Con espacios alrededor para que "Research / NVDA" no se confunda con
# el nombre de una carpeta que contenga una barra.
_PATH_SEPARATOR = " / "

_EXCERPT_LENGTH = 180


class FolderNotFoundError(Exception):
    """La carpeta no existe, o es de otro usuario. Un solo error para los dos casos: si "existe
    pero no es tuya" tuviera una respuesta distinta de "no existe", cualquiera podría enumerar
    carpetas ajenas probando UUIDs.
    """


class NoteNotFoundError(Exception):
    """Ídem para las notas."""


class DuplicateFolderNameError(Exception):
    """Ya hay una carpeta con ese nombre en el mismo nivel."""


class FolderCycleError(Exception):
    """El movimiento pedido haría que una carpeta sea su propia ancestra."""


class FolderDepthExceededError(Exception):
    """El movimiento o la creación pasaría el tope de profundidad."""


def _excerpt(content: str) -> str:
    """Vista previa del cuerpo para los listados.

    Se colapsan los saltos de línea: un markdown con títulos y viñetas produce un excerpt con
    huecos verticales que rompe la altura de las filas de la lista.
    """

    flattened = " ".join(content.split())
    if len(flattened) <= _EXCERPT_LENGTH:
        return flattened
    return f"{flattened[:_EXCERPT_LENGTH].rstrip()}…"


def _to_summary(note: Note) -> NoteSummary:
    return NoteSummary(
        id=note.id,
        folder_id=note.folder_id,
        ticker=note.ticker,
        title=note.title,
        pinned=note.pinned,
        created_at=note.created_at,
        updated_at=note.updated_at,
        excerpt=_excerpt(note.content),
        content_length=len(note.content),
    )


class NotesService:
    """Sin caché y sin clientes externos: son lecturas y escrituras de la base local, y son datos
    que el usuario acaba de escribir — cachear sus propias notas haría que su edición tarde en
    aparecer, que es el peor lugar posible para una caché.
    """

    def __init__(self, session_factory: async_sessionmaker[AsyncSession]) -> None:
        self._session_factory = session_factory

    # --- Carpetas ---------------------------------------------------------------------------

    async def list_folders(self, user_id: UUID) -> list[FolderRead]:
        """El árbol completo como lista PLANA ordenada por ruta, con profundidad y conteos.

        Se traen todas las carpetas del usuario en UNA consulta y el árbol se arma en memoria. La
        alternativa (una CTE recursiva) sería más elegante en SQL pero acá no paga: el árbol de
        carpetas de un usuario son decenas de filas, no miles, y una CTE recursiva tendría que
        escribirse distinto para SQLite y PostgreSQL — los dos motores que este proyecto soporta.
        """

        async with self._session_factory() as session:
            folders = list(
                (
                    await session.scalars(
                        select(Folder).where(Folder.user_id == user_id)
                    )
                ).all()
            )
            count_rows = (
                await session.execute(
                    select(Note.folder_id, func.count())
                    .where(Note.user_id == user_id, Note.folder_id.is_not(None))
                    .group_by(Note.folder_id)
                )
            ).all()
            note_counts: dict[UUID, int] = {
                folder_id: count
                for folder_id, count in count_rows
                if folder_id is not None
            }

        return _build_folder_tree(folders, note_counts)

    async def create_folder(self, user_id: UUID, payload: FolderCreate) -> FolderRead:
        async with self._session_factory() as session:
            parent = await self._load_folder_or_raise(
                session, user_id, payload.parent_id
            )
            if parent is not None:
                depth = await self._depth_of(session, user_id, parent)
                if depth + 1 > MAX_FOLDER_DEPTH:
                    raise FolderDepthExceededError(str(MAX_FOLDER_DEPTH))

            await self._ensure_name_available(
                session, user_id, name=payload.name, parent_id=payload.parent_id
            )

            folder = Folder(
                user_id=user_id, name=payload.name, parent_id=payload.parent_id
            )
            session.add(folder)
            await session.commit()
            await session.refresh(folder)

        # Se relee el árbol para devolver la carpeta con su `depth`/`path`/conteos ya calculados: el
        # cliente que acaba de crearla necesita insertarla en la lista que ya tiene, y armar esos
        # campos a mano del lado del cliente los duplicaría.
        return await self._folder_read_or_raise(user_id, folder.id)

    async def update_folder(
        self, user_id: UUID, folder_id: UUID, payload: FolderUpdate
    ) -> FolderRead:
        async with self._session_factory() as session:
            folder = await self._load_folder_or_raise(session, user_id, folder_id)
            if folder is None:
                raise FolderNotFoundError(str(folder_id))

            provided = payload.model_fields_set
            # `parent_id` presente en el request (aunque valga None) significa mover; ausente
            # significa dejarlo donde está. Sin esta distinción, mover una subcarpeta a la raíz
            # sería imposible de expresar.
            moving = "parent_id" in provided
            new_parent_id = payload.parent_id if moving else folder.parent_id
            new_name = payload.name if payload.name is not None else folder.name

            if moving and new_parent_id is not None:
                if new_parent_id == folder.id:
                    raise FolderCycleError(str(folder_id))
                new_parent = await self._load_folder_or_raise(
                    session, user_id, new_parent_id
                )
                if new_parent is None:
                    raise FolderNotFoundError(str(new_parent_id))
                if await self._is_descendant(
                    session, user_id, ancestor_id=folder.id, candidate=new_parent
                ):
                    raise FolderCycleError(str(folder_id))

                parent_depth = await self._depth_of(session, user_id, new_parent)
                subtree_height = await self._subtree_height(session, user_id, folder.id)
                if parent_depth + 1 + subtree_height > MAX_FOLDER_DEPTH:
                    # Se valida la altura del SUBÁRBOL, no solo la de la carpeta movida: arrastrar
                    # tres niveles de hijas a un padre profundo pasaría el tope aunque la carpeta
                    # movida sola entrara.
                    raise FolderDepthExceededError(str(MAX_FOLDER_DEPTH))

            if new_name != folder.name or new_parent_id != folder.parent_id:
                await self._ensure_name_available(
                    session,
                    user_id,
                    name=new_name,
                    parent_id=new_parent_id,
                    exclude_id=folder.id,
                )

            folder.name = new_name
            folder.parent_id = new_parent_id
            await session.commit()

        return await self._folder_read_or_raise(user_id, folder_id)

    async def delete_folder(
        self, user_id: UUID, folder_id: UUID, *, cascade: bool = False
    ) -> FolderDeletionResult:
        """Borra una carpeta.

        Con `cascade=False` (el default) **no se pierde nada**: las notas de la carpeta pasan a la
        raíz y las subcarpetas suben un nivel. Es la política por defecto porque el costo de los dos
        errores no es simétrico — encontrar una nota en la raíz es una molestia, perder una tesis
        escrita a mano es irreparable.

        Con `cascade=True` se borra el subárbol completo con sus notas. Existe porque "archivé un
        proyecto entero y quiero que desaparezca" es un pedido real, pero tiene que ser explícito.
        """

        async with self._session_factory() as session:
            folder = await self._load_folder_or_raise(session, user_id, folder_id)
            if folder is None:
                raise FolderNotFoundError(str(folder_id))

            if cascade:
                subtree = await self._collect_subtree(session, user_id, folder_id)
                folder_ids = [folder_id, *subtree]
                deleted_notes = await self._delete_notes_in(
                    session, user_id, folder_ids
                )
                # Se borran de la hoja hacia la raíz para que ninguna fila quede apuntando a un
                # padre ya borrado en el medio de la transacción.
                for target_id in reversed(folder_ids):
                    target = await session.get(Folder, target_id)
                    if target is not None:
                        await session.delete(target)
                await session.commit()
                return FolderDeletionResult(
                    deleted_folder_id=folder_id,
                    cascade=True,
                    deleted_folders=len(subtree),
                    deleted_notes=deleted_notes,
                )

            children = list(
                (
                    await session.scalars(
                        select(Folder).where(
                            Folder.user_id == user_id, Folder.parent_id == folder_id
                        )
                    )
                ).all()
            )
            notes = list(
                (
                    await session.scalars(
                        select(Note).where(
                            Note.user_id == user_id, Note.folder_id == folder_id
                        )
                    )
                ).all()
            )

            for child in children:
                # Las hijas suben al abuelo. Si la carpeta borrada estaba en la raíz, sus hijas
                # pasan a ser de raíz — nunca quedan apuntando a la carpeta que ya no existe.
                child.parent_id = folder.parent_id
            for note in notes:
                note.folder_id = None

            # Los nombres de las hijas que suben pueden chocar con los de sus nuevas hermanas. No se
            # rechaza el borrado por eso: se les agrega un sufijo para conservar la regla de unicidad
            # sin bloquear una operación que el usuario ya pidió. Bloquear el borrado de una carpeta
            # por un choque de nombres entre otras dos sería incomprensible.
            await self._deduplicate_names(
                session, user_id, parent_id=folder.parent_id, moved=children
            )

            await session.delete(folder)
            await session.commit()

            return FolderDeletionResult(
                deleted_folder_id=folder_id,
                cascade=False,
                reparented_folders=len(children),
                detached_notes=len(notes),
            )

    # --- Notas ------------------------------------------------------------------------------

    async def list_notes(
        self,
        user_id: UUID,
        *,
        folder_id: UUID | None = None,
        root_only: bool = False,
        ticker: str | None = None,
        query: str | None = None,
        limit: int = 50,
        offset: int = 0,
    ) -> NotePage:
        """Listado de notas, filtrable por carpeta, por ticker y por texto.

        `folder_id` y `root_only` son dos filtros distintos y por eso son dos parámetros: sin
        `root_only`, "las notas sin carpeta" no se podría expresar — un `folder_id` ausente
        significa "de cualquier carpeta", y no hay forma de mandar "IS NULL" en un query param sin
        inventar un valor centinela.
        """

        filters = [Note.user_id == user_id]
        if root_only:
            filters.append(Note.folder_id.is_(None))
        elif folder_id is not None:
            filters.append(Note.folder_id == folder_id)
        if ticker:
            filters.append(Note.ticker == ticker.upper())
        if query:
            # Se busca en título Y cuerpo: quien recuerda una frase de su tesis no recuerda el
            # título con el que la guardó.
            pattern = f"%{query}%"
            filters.append(or_(Note.title.ilike(pattern), Note.content.ilike(pattern)))

        async with self._session_factory() as session:
            total = await session.scalar(
                select(func.count()).select_from(Note).where(*filters)
            )
            rows = await session.scalars(
                select(Note)
                .where(*filters)
                # Fijadas primero y después por última edición: es el orden en que el usuario espera
                # encontrar su trabajo. `desc()` sobre `pinned` porque True > False.
                .order_by(Note.pinned.desc(), Note.updated_at.desc())
                .limit(limit)
                .offset(offset)
            )
            items = [_to_summary(note) for note in rows.all()]

        return NotePage(items=items, total=total or 0, limit=limit, offset=offset)

    async def get_note(self, user_id: UUID, note_id: UUID) -> NoteRead:
        async with self._session_factory() as session:
            note = await self._load_note_or_raise(session, user_id, note_id)
            return NoteRead.model_validate(note)

    async def create_note(self, user_id: UUID, payload: NoteCreate) -> NoteRead:
        async with self._session_factory() as session:
            if payload.folder_id is not None:
                folder = await self._load_folder_or_raise(
                    session, user_id, payload.folder_id
                )
                if folder is None:
                    # Se valida que la carpeta exista Y sea del usuario: sin esto, un cliente podría
                    # archivar notas propias dentro de la carpeta de otro y verlas desaparecer.
                    raise FolderNotFoundError(str(payload.folder_id))

            note = Note(
                user_id=user_id,
                folder_id=payload.folder_id,
                ticker=payload.ticker.upper() if payload.ticker else None,
                title=payload.title,
                content=payload.content,
                pinned=payload.pinned,
            )
            session.add(note)
            await session.commit()
            await session.refresh(note)
            return NoteRead.model_validate(note)

    async def update_note(
        self, user_id: UUID, note_id: UUID, payload: NoteUpdate
    ) -> NoteRead:
        async with self._session_factory() as session:
            note = await self._load_note_or_raise(session, user_id, note_id)
            provided = payload.model_fields_set

            if payload.title is not None:
                note.title = payload.title
            if payload.content is not None:
                note.content = payload.content
            if payload.pinned is not None:
                note.pinned = payload.pinned

            # Igual que en las carpetas: `null` explícito saca la nota de su carpeta o la desvincula
            # del ticker, y para eso hay que distinguirlo de "campo omitido".
            if "folder_id" in provided:
                if payload.folder_id is not None:
                    folder = await self._load_folder_or_raise(
                        session, user_id, payload.folder_id
                    )
                    if folder is None:
                        raise FolderNotFoundError(str(payload.folder_id))
                note.folder_id = payload.folder_id
            if "ticker" in provided:
                note.ticker = payload.ticker.upper() if payload.ticker else None

            await session.commit()
            await session.refresh(note)
            return NoteRead.model_validate(note)

    async def delete_note(self, user_id: UUID, note_id: UUID) -> None:
        async with self._session_factory() as session:
            note = await self._load_note_or_raise(session, user_id, note_id)
            await session.delete(note)
            await session.commit()

    # --- Internos ---------------------------------------------------------------------------

    async def _folder_read_or_raise(self, user_id: UUID, folder_id: UUID) -> FolderRead:
        folders = await self.list_folders(user_id)
        found = next((item for item in folders if item.id == folder_id), None)
        if found is None:
            raise FolderNotFoundError(str(folder_id))
        return found

    async def _load_folder_or_raise(
        self, session: AsyncSession, user_id: UUID, folder_id: UUID | None
    ) -> Folder | None:
        """Carga una carpeta del usuario. Devuelve `None` cuando `folder_id` es `None` (la raíz no
        es una carpeta) y también cuando no existe o es de otro usuario — el llamador decide si eso
        es un error o el caso normal.
        """

        if folder_id is None:
            return None
        return await session.scalar(
            select(Folder).where(Folder.id == folder_id, Folder.user_id == user_id)
        )

    async def _load_note_or_raise(
        self, session: AsyncSession, user_id: UUID, note_id: UUID
    ) -> Note:
        note = await session.scalar(
            select(Note).where(Note.id == note_id, Note.user_id == user_id)
        )
        if note is None:
            raise NoteNotFoundError(str(note_id))
        return note

    async def _ensure_name_available(
        self,
        session: AsyncSession,
        user_id: UUID,
        *,
        name: str,
        parent_id: UUID | None,
        exclude_id: UUID | None = None,
    ) -> None:
        """Rechaza un nombre ya usado por una hermana.

        La comparación es case-insensitive: "Research" y "research" en el mismo nivel son el mismo
        problema de ambigüedad que dos idénticas.
        """

        filters = [
            Folder.user_id == user_id,
            func.lower(Folder.name) == name.strip().lower(),
        ]
        filters.append(
            Folder.parent_id.is_(None)
            if parent_id is None
            else Folder.parent_id == parent_id
        )
        if exclude_id is not None:
            filters.append(Folder.id != exclude_id)

        clash = await session.scalar(select(Folder.id).where(*filters))
        if clash is not None:
            raise DuplicateFolderNameError(name)

    async def _deduplicate_names(
        self,
        session: AsyncSession,
        user_id: UUID,
        *,
        parent_id: UUID | None,
        moved: list[Folder],
    ) -> None:
        """Renombra con un sufijo las carpetas recién movidas cuyo nombre choque en su nuevo nivel."""

        for folder in moved:
            candidate = folder.name
            suffix = 2
            while True:
                try:
                    await self._ensure_name_available(
                        session,
                        user_id,
                        name=candidate,
                        parent_id=parent_id,
                        exclude_id=folder.id,
                    )
                    break
                except DuplicateFolderNameError:
                    candidate = f"{folder.name} ({suffix})"
                    suffix += 1
            if candidate != folder.name:
                # `folder_name` y no `name`: `name` es un campo propio de `LogRecord` y pasarlo por
                # `extra` lo sobreescribiría.
                logger.info(
                    "notes_folder_renamed_on_reparent",
                    extra={"folder_id": str(folder.id), "folder_name": candidate},
                )
                folder.name = candidate

    async def _depth_of(
        self, session: AsyncSession, user_id: UUID, folder: Folder
    ) -> int:
        """Profundidad de una carpeta (0 = raíz), subiendo por la cadena de ancestros.

        El corte por `MAX_FOLDER_DEPTH` no es solo una optimización: si por un bug quedara un ciclo
        en la base, este bucle no terminaría nunca y colgaría el request.
        """

        depth = 0
        current = folder
        while current.parent_id is not None and depth <= MAX_FOLDER_DEPTH + 1:
            parent = await self._load_folder_or_raise(
                session, user_id, current.parent_id
            )
            if parent is None:
                break
            current = parent
            depth += 1
        return depth

    async def _is_descendant(
        self,
        session: AsyncSession,
        user_id: UUID,
        *,
        ancestor_id: UUID,
        candidate: Folder,
    ) -> bool:
        """¿`candidate` está dentro del subárbol de `ancestor_id`?

        Es el chequeo que impide el ciclo al mover: si el nuevo padre desciende de la carpeta que se
        está moviendo, el movimiento cerraría el ciclo.
        """

        current: Folder | None = candidate
        steps = 0
        while current is not None and steps <= MAX_FOLDER_DEPTH + 1:
            if current.id == ancestor_id:
                return True
            current = await self._load_folder_or_raise(
                session, user_id, current.parent_id
            )
            steps += 1
        return False

    async def _collect_subtree(
        self, session: AsyncSession, user_id: UUID, folder_id: UUID
    ) -> list[UUID]:
        """Ids del subárbol de una carpeta, en orden de profundidad creciente (sin incluirla)."""

        collected: list[UUID] = []
        frontier = [folder_id]
        while frontier:
            rows = list(
                (
                    await session.scalars(
                        select(Folder.id).where(
                            Folder.user_id == user_id,
                            Folder.parent_id.in_(frontier),
                        )
                    )
                ).all()
            )
            # Se descarta lo ya visto: si por un bug quedara un ciclo, sin esto el bucle no
            # terminaría.
            fresh = [row for row in rows if row not in collected and row != folder_id]
            if not fresh:
                break
            collected.extend(fresh)
            frontier = fresh
        return collected

    async def _subtree_height(
        self, session: AsyncSession, user_id: UUID, folder_id: UUID
    ) -> int:
        """Cuántos niveles cuelgan de una carpeta (0 si no tiene hijas)."""

        height = 0
        frontier = [folder_id]
        seen: set[UUID] = {folder_id}
        while frontier and height <= MAX_FOLDER_DEPTH + 1:
            rows = list(
                (
                    await session.scalars(
                        select(Folder.id).where(
                            Folder.user_id == user_id, Folder.parent_id.in_(frontier)
                        )
                    )
                ).all()
            )
            fresh = [row for row in rows if row not in seen]
            if not fresh:
                break
            seen.update(fresh)
            frontier = fresh
            height += 1
        return height

    async def _delete_notes_in(
        self, session: AsyncSession, user_id: UUID, folder_ids: list[UUID]
    ) -> int:
        notes = list(
            (
                await session.scalars(
                    select(Note).where(
                        Note.user_id == user_id, Note.folder_id.in_(folder_ids)
                    )
                )
            ).all()
        )
        for note in notes:
            await session.delete(note)
        return len(notes)


def _build_folder_tree(
    folders: list[Folder], note_counts: dict[UUID, int]
) -> list[FolderRead]:
    """Convierte las filas planas en la lista ordenada por ruta que expone la API.

    Se recorre en profundidad desde la raíz, así que una carpeta huérfana —una que apunta a un padre
    que no está en la lista, lo que no debería pasar pero pasaría con datos corruptos— queda AFUERA
    del resultado. Es deliberado: incluirla sin ruta la haría aparecer en un nivel que no le
    corresponde, y esconderla deja el árbol coherente y el problema visible en el conteo.
    """

    children_by_parent: dict[UUID | None, list[Folder]] = {}
    for folder in folders:
        children_by_parent.setdefault(folder.parent_id, []).append(folder)
    for siblings in children_by_parent.values():
        # Orden alfabético entre hermanas, insensible a mayúsculas: es el orden que la UI espera y
        # el que hace estable la ruta.
        siblings.sort(key=lambda item: item.name.lower())

    result: list[FolderRead] = []

    def walk(parent_id: UUID | None, depth: int, prefix: str) -> None:
        for folder in children_by_parent.get(parent_id, []):
            path = f"{prefix}{folder.name}"
            result.append(
                FolderRead(
                    id=folder.id,
                    name=folder.name,
                    parent_id=folder.parent_id,
                    created_at=folder.created_at,
                    updated_at=folder.updated_at,
                    depth=depth,
                    path=path,
                    note_count=note_counts.get(folder.id, 0),
                    subfolder_count=len(children_by_parent.get(folder.id, [])),
                )
            )
            walk(folder.id, depth + 1, f"{path}{_PATH_SEPARATOR}")

    walk(None, 0, "")
    return result
