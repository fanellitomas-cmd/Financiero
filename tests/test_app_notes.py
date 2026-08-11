"""Tests de `/api/v1/notes` — las notas de investigación del Investment Lab.

Lo que este bloque promete y que es fácil de romper sin darse cuenta:

  1. **El listado NO trae el cuerpo.** Devuelve resúmenes con `excerpt` y `content_length`; si
     alguna vez empezara a devolver `content`, una carpeta con 50 tesis serían megabytes por cada
     apertura de la pantalla.
  2. **`null` explícito desarchiva.** Sacar una nota de su carpeta (o desvincularla del ticker) se
     expresa mandando `null`; omitir el campo significa "no cambiar". Sin esa distinción una nota
     archivada no podría volver a la raíz.
  3. **`root_only` no se puede expresar con `folder_id`.** Omitir `folder_id` significa "de
     cualquier carpeta", así que "las notas sin carpeta" necesita su propio parámetro.
  4. **Una nota ajena responde 404, no 403**, en lectura, edición y borrado.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from uuid import UUID

import httpx
from sqlalchemy import update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.note import Note


async def _register_and_login(client: httpx.AsyncClient, email: str) -> dict[str, str]:
    await client.post(
        "/api/v1/auth/register", json={"email": email, "password": "supersecreta1"}
    )
    login_response = await client.post(
        "/api/v1/auth/login", json={"email": email, "password": "supersecreta1"}
    )
    token = login_response.json()["access_token"]
    return {"Authorization": f"Bearer {token}"}


async def _create_folder(
    client: httpx.AsyncClient, headers: dict[str, str], name: str
) -> dict[str, object]:
    response = await client.post(
        "/api/v1/folders", json={"name": name}, headers=headers
    )
    assert response.status_code == 201, response.text
    created: dict[str, object] = response.json()
    return created


async def _create_note(
    client: httpx.AsyncClient, headers: dict[str, str], title: str, **extra: object
) -> dict[str, object]:
    response = await client.post(
        "/api/v1/notes", json={"title": title, **extra}, headers=headers
    )
    assert response.status_code == 201, response.text
    created: dict[str, object] = response.json()
    return created


async def _stamp_updated_at(
    session_factory: async_sessionmaker[AsyncSession],
    note_id: str,
    moment: datetime,
) -> None:
    """Fija `updated_at` de una nota a mano.

    Necesario para probar el orden: en SQLite `CURRENT_TIMESTAMP` tiene resolución de un segundo, así
    que varias notas creadas en el mismo test empatan y el orden real quedaría indeterminado. Se usa
    un `update()` de Core y no una asignación del ORM porque el `onupdate` de la columna no se aplica
    a las columnas que ya vienen en el SET.
    """

    async with session_factory() as session:
        await session.execute(
            update(Note).where(Note.id == UUID(note_id)).values(updated_at=moment)
        )
        await session.commit()


# --- Autenticación -----------------------------------------------------------------------------


async def test_notes_require_authentication(client: httpx.AsyncClient) -> None:
    assert (await client.get("/api/v1/notes")).status_code == 401
    assert (
        await client.post("/api/v1/notes", json={"title": "Tesis"})
    ).status_code == 401
    assert (
        await client.get("/api/v1/notes/11111111-1111-4111-8111-111111111111")
    ).status_code == 401


# --- Creación ----------------------------------------------------------------------------------


async def test_create_note_defaults_to_root_with_empty_body(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "notes-defaults@example.com")

    note = await _create_note(client, headers, "Ideas sueltas")

    assert note["title"] == "Ideas sueltas"
    assert note["content"] == ""
    assert note["folder_id"] is None
    assert note["ticker"] is None
    assert note["pinned"] is False


async def test_create_note_with_folder_and_ticker_normalizes_the_symbol(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "notes-create-full@example.com")
    folder = await _create_folder(client, headers, "Research")

    note = await _create_note(
        client,
        headers,
        "Tesis NVDA",
        content="# Tesis\n\nEl data center sigue traccionando.",
        folder_id=str(folder["id"]),
        # Se manda en minúsculas: el servicio normaliza a mayúsculas para que el filtro por ticker
        # encuentre la nota sin importar cómo la escribió el cliente.
        ticker="nvda",
        pinned=True,
    )

    assert note["folder_id"] == folder["id"]
    assert note["ticker"] == "NVDA"
    assert note["pinned"] is True
    content = note["content"]
    assert isinstance(content, str)
    assert content.startswith("# Tesis")


async def test_create_note_in_unknown_or_foreign_folder_is_404(
    client: httpx.AsyncClient,
) -> None:
    owner = await _register_and_login(client, "notes-folder-owner@example.com")
    intruder = await _register_and_login(client, "notes-folder-intruder@example.com")
    victim = await _create_folder(client, owner, "Privada")

    unknown = await client.post(
        "/api/v1/notes",
        json={
            "title": "Huérfana",
            "folder_id": "11111111-1111-4111-8111-111111111111",
        },
        headers=owner,
    )
    foreign = await client.post(
        "/api/v1/notes",
        json={"title": "Intrusa", "folder_id": str(victim["id"])},
        headers=intruder,
    )

    assert unknown.status_code == 404
    # Sin este chequeo un usuario archivaría notas propias en la carpeta de otro y las vería
    # desaparecer de su propio listado.
    assert foreign.status_code == 404


async def test_invalid_note_payloads_are_rejected(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "notes-invalid@example.com")

    empty_title = await client.post(
        "/api/v1/notes", json={"title": ""}, headers=headers
    )
    huge_body = await client.post(
        "/api/v1/notes",
        json={"title": "Larga", "content": "x" * 60_001},
        headers=headers,
    )
    unknown_field = await client.post(
        "/api/v1/notes", json={"title": "Ok", "color": "rojo"}, headers=headers
    )

    assert empty_title.status_code == 422
    # El tope existe para que el error sea un 422 legible y no una falla del driver.
    assert huge_body.status_code == 422
    assert unknown_field.status_code == 422


# --- Lectura -----------------------------------------------------------------------------------


async def test_get_note_returns_the_full_body(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "notes-get@example.com")
    body = "Párrafo largo. " * 40
    note = await _create_note(client, headers, "Tesis", content=body)

    response = await client.get(f"/api/v1/notes/{note['id']}", headers=headers)

    assert response.status_code == 200
    assert response.json()["content"] == body


async def test_get_unknown_or_foreign_note_is_404(client: httpx.AsyncClient) -> None:
    owner = await _register_and_login(client, "notes-get-owner@example.com")
    intruder = await _register_and_login(client, "notes-get-intruder@example.com")
    note = await _create_note(client, owner, "Privada", content="secreto")

    unknown = await client.get(
        "/api/v1/notes/11111111-1111-4111-8111-111111111111", headers=owner
    )
    foreign = await client.get(f"/api/v1/notes/{note['id']}", headers=intruder)

    assert unknown.status_code == 404
    assert foreign.status_code == 404


# --- Listado -----------------------------------------------------------------------------------


async def test_listing_returns_summaries_without_the_body(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "notes-summary@example.com")
    body = "\n\n".join(["# Título", "Primera línea de la tesis.", "y sigue " * 60])
    await _create_note(client, headers, "Tesis NVDA", content=body, ticker="NVDA")

    response = await client.get("/api/v1/notes", headers=headers)

    assert response.status_code == 200
    page = response.json()
    assert page["total"] == 1
    assert page["limit"] == 50
    assert page["offset"] == 0
    item = page["items"][0]
    # El cuerpo NO viaja en el listado, ni siquiera como campo vacío.
    assert "content" not in item
    assert item["content_length"] == len(body)
    # El excerpt colapsa los saltos de línea: un markdown con títulos y viñetas produciría una vista
    # previa con huecos verticales que rompe la altura de las filas.
    assert "\n" not in item["excerpt"]
    assert item["excerpt"].startswith("# Título Primera línea de la tesis.")
    assert item["excerpt"].endswith("…")
    assert len(item["excerpt"]) <= 181


async def test_short_body_excerpt_has_no_ellipsis(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "notes-short-excerpt@example.com")
    await _create_note(client, headers, "Corta", content="Dos palabras")

    response = await client.get("/api/v1/notes", headers=headers)

    assert response.json()["items"][0]["excerpt"] == "Dos palabras"
    assert response.json()["items"][0]["content_length"] == 12


async def test_listing_filters_by_folder(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "notes-by-folder@example.com")
    research = await _create_folder(client, headers, "Research")
    trades = await _create_folder(client, headers, "Trades")
    filed = await _create_note(
        client, headers, "Archivada", folder_id=str(research["id"])
    )
    await _create_note(client, headers, "En trades", folder_id=str(trades["id"]))
    await _create_note(client, headers, "Suelta")

    response = await client.get(
        "/api/v1/notes", params={"folder_id": str(research["id"])}, headers=headers
    )

    assert response.json()["total"] == 1
    assert [item["id"] for item in response.json()["items"]] == [filed["id"]]


async def test_root_only_returns_unfiled_notes_and_wins_over_folder_id(
    client: httpx.AsyncClient,
) -> None:
    """`root_only` y `folder_id` son dos preguntas distintas y no se combinan: mandarlas juntas
    resuelve por `root_only` en vez de devolver una intersección vacía que parecería un bug.
    """

    headers = await _register_and_login(client, "notes-root-only@example.com")
    folder = await _create_folder(client, headers, "Research")
    await _create_note(client, headers, "Archivada", folder_id=str(folder["id"]))
    loose = await _create_note(client, headers, "Suelta")

    only_root = await client.get(
        "/api/v1/notes", params={"root_only": True}, headers=headers
    )
    both = await client.get(
        "/api/v1/notes",
        params={"root_only": True, "folder_id": str(folder["id"])},
        headers=headers,
    )

    assert [item["id"] for item in only_root.json()["items"]] == [loose["id"]]
    assert [item["id"] for item in both.json()["items"]] == [loose["id"]]


async def test_listing_filters_by_ticker_case_insensitively(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "notes-by-ticker@example.com")
    nvda = await _create_note(client, headers, "Tesis NVDA", ticker="NVDA")
    await _create_note(client, headers, "Tesis AAPL", ticker="AAPL")
    await _create_note(client, headers, "Sin ticker")

    response = await client.get(
        "/api/v1/notes", params={"ticker": "nvda"}, headers=headers
    )

    assert [item["id"] for item in response.json()["items"]] == [nvda["id"]]


async def test_text_search_matches_title_and_body(client: httpx.AsyncClient) -> None:
    """Se busca en título Y cuerpo: quien recuerda una frase de su tesis no recuerda el título con el
    que la guardó.
    """

    headers = await _register_and_login(client, "notes-search@example.com")
    by_title = await _create_note(client, headers, "Margen bruto de NVDA")
    by_body = await _create_note(
        client, headers, "Notas varias", content="El margen bruto se expandió 400 pbs."
    )
    await _create_note(client, headers, "Otra cosa", content="Nada que ver.")

    response = await client.get(
        "/api/v1/notes", params={"q": "margen"}, headers=headers
    )

    assert response.json()["total"] == 2
    assert {item["id"] for item in response.json()["items"]} == {
        by_title["id"],
        by_body["id"],
    }


async def test_filters_combine(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "notes-combined@example.com")
    folder = await _create_folder(client, headers, "Research")
    target = await _create_note(
        client,
        headers,
        "Tesis NVDA",
        folder_id=str(folder["id"]),
        ticker="NVDA",
        content="margen bruto",
    )
    await _create_note(
        client, headers, "Tesis NVDA vieja", ticker="NVDA", content="margen bruto"
    )
    await _create_note(
        client,
        headers,
        "Otra de la carpeta",
        folder_id=str(folder["id"]),
        ticker="AAPL",
    )

    response = await client.get(
        "/api/v1/notes",
        params={"folder_id": str(folder["id"]), "ticker": "NVDA", "q": "margen"},
        headers=headers,
    )

    assert [item["id"] for item in response.json()["items"]] == [target["id"]]


async def test_pinned_notes_come_first_then_most_recently_edited(
    client: httpx.AsyncClient, db_session_factory: async_sessionmaker[AsyncSession]
) -> None:
    headers = await _register_and_login(client, "notes-order@example.com")
    old_pinned = await _create_note(client, headers, "Fijada vieja", pinned=True)
    new_pinned = await _create_note(client, headers, "Fijada nueva", pinned=True)
    old_plain = await _create_note(client, headers, "Suelta vieja")
    new_plain = await _create_note(client, headers, "Suelta nueva")

    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    await _stamp_updated_at(db_session_factory, str(old_pinned["id"]), base)
    await _stamp_updated_at(
        db_session_factory, str(new_pinned["id"]), base + timedelta(days=3)
    )
    await _stamp_updated_at(
        db_session_factory, str(old_plain["id"]), base + timedelta(days=1)
    )
    await _stamp_updated_at(
        db_session_factory, str(new_plain["id"]), base + timedelta(days=2)
    )

    response = await client.get("/api/v1/notes", headers=headers)

    # Las fijadas primero aunque una suelta sea más reciente; dentro de cada grupo, la última edición
    # arriba.
    assert [item["title"] for item in response.json()["items"]] == [
        "Fijada nueva",
        "Fijada vieja",
        "Suelta nueva",
        "Suelta vieja",
    ]


async def test_listing_paginates_and_reports_the_full_total(
    client: httpx.AsyncClient, db_session_factory: async_sessionmaker[AsyncSession]
) -> None:
    headers = await _register_and_login(client, "notes-paging@example.com")
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    for index in range(5):
        note = await _create_note(client, headers, f"Nota {index}")
        await _stamp_updated_at(
            db_session_factory, str(note["id"]), base + timedelta(days=index)
        )

    first = await client.get(
        "/api/v1/notes", params={"limit": 2, "offset": 0}, headers=headers
    )
    second = await client.get(
        "/api/v1/notes", params={"limit": 2, "offset": 2}, headers=headers
    )

    # `total` es el total del filtro, no el de la página: es lo que la UI necesita para el contador.
    assert first.json()["total"] == 5
    assert [item["title"] for item in first.json()["items"]] == ["Nota 4", "Nota 3"]
    assert second.json()["total"] == 5
    assert [item["title"] for item in second.json()["items"]] == ["Nota 2", "Nota 1"]


async def test_pagination_bounds_are_validated(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "notes-paging-bounds@example.com")

    assert (
        await client.get("/api/v1/notes", params={"limit": 0}, headers=headers)
    ).status_code == 422
    assert (
        await client.get("/api/v1/notes", params={"limit": 101}, headers=headers)
    ).status_code == 422
    assert (
        await client.get("/api/v1/notes", params={"offset": -1}, headers=headers)
    ).status_code == 422


async def test_listing_only_shows_own_notes(client: httpx.AsyncClient) -> None:
    first = await _register_and_login(client, "notes-iso-a@example.com")
    second = await _register_and_login(client, "notes-iso-b@example.com")
    mine = await _create_note(client, first, "Mía", ticker="NVDA")
    await _create_note(client, second, "Ajena", ticker="NVDA")

    response = await client.get(
        "/api/v1/notes", params={"ticker": "NVDA"}, headers=first
    )

    assert response.json()["total"] == 1
    assert [item["id"] for item in response.json()["items"]] == [mine["id"]]


# --- Edición -----------------------------------------------------------------------------------


async def test_patch_edits_title_body_and_pin(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "notes-edit@example.com")
    note = await _create_note(client, headers, "Borrador", content="algo")

    response = await client.patch(
        f"/api/v1/notes/{note['id']}",
        json={"title": "Tesis final", "content": "Cuerpo nuevo.", "pinned": True},
        headers=headers,
    )

    assert response.status_code == 200
    assert response.json()["title"] == "Tesis final"
    assert response.json()["content"] == "Cuerpo nuevo."
    assert response.json()["pinned"] is True


async def test_patch_moves_a_note_between_folders(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "notes-move@example.com")
    research = await _create_folder(client, headers, "Research")
    trades = await _create_folder(client, headers, "Trades")
    note = await _create_note(client, headers, "Tesis", folder_id=str(research["id"]))

    response = await client.patch(
        f"/api/v1/notes/{note['id']}",
        json={"folder_id": str(trades["id"])},
        headers=headers,
    )

    assert response.status_code == 200
    assert response.json()["folder_id"] == trades["id"]


async def test_explicit_nulls_unfile_the_note_and_clear_the_ticker(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "notes-detach@example.com")
    folder = await _create_folder(client, headers, "Research")
    note = await _create_note(
        client, headers, "Tesis", folder_id=str(folder["id"]), ticker="NVDA"
    )

    response = await client.patch(
        f"/api/v1/notes/{note['id']}",
        json={"folder_id": None, "ticker": None},
        headers=headers,
    )

    assert response.status_code == 200
    assert response.json()["folder_id"] is None
    assert response.json()["ticker"] is None


async def test_omitted_fields_are_left_untouched(client: httpx.AsyncClient) -> None:
    """El contraste con el test anterior es el punto: `null` desvincula, ausente no cambia nada."""

    headers = await _register_and_login(client, "notes-partial@example.com")
    folder = await _create_folder(client, headers, "Research")
    note = await _create_note(
        client,
        headers,
        "Tesis",
        content="cuerpo original",
        folder_id=str(folder["id"]),
        ticker="NVDA",
        pinned=True,
    )

    response = await client.patch(
        f"/api/v1/notes/{note['id']}", json={"title": "Tesis v2"}, headers=headers
    )

    assert response.status_code == 200
    updated = response.json()
    assert updated["title"] == "Tesis v2"
    # Todo lo que no vino en el request quedó igual, incluida la carpeta y el ticker.
    for field in ("content", "folder_id", "ticker", "pinned", "created_at"):
        assert updated[field] == note[field]


async def test_patch_can_blank_the_body_with_an_empty_string(
    client: httpx.AsyncClient,
) -> None:
    """Vaciar el cuerpo se hace con `""`, que es distinto de omitirlo. Un `null` en `content`
    significa "no cambiar", igual que la ausencia.
    """

    headers = await _register_and_login(client, "notes-blank-body@example.com")
    note = await _create_note(client, headers, "Tesis", content="algo escrito")

    response = await client.patch(
        f"/api/v1/notes/{note['id']}", json={"content": ""}, headers=headers
    )

    assert response.status_code == 200
    assert response.json()["content"] == ""


async def test_patch_normalizes_a_new_ticker(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "notes-patch-ticker@example.com")
    note = await _create_note(client, headers, "Tesis")

    response = await client.patch(
        f"/api/v1/notes/{note['id']}", json={"ticker": "aapl"}, headers=headers
    )

    assert response.json()["ticker"] == "AAPL"


async def test_patch_into_unknown_or_foreign_folder_is_404(
    client: httpx.AsyncClient,
) -> None:
    owner = await _register_and_login(client, "notes-patch-owner@example.com")
    intruder = await _register_and_login(client, "notes-patch-intruder@example.com")
    victim_folder = await _create_folder(client, owner, "Privada")
    note = await _create_note(client, intruder, "Mía")

    unknown = await client.patch(
        f"/api/v1/notes/{note['id']}",
        json={"folder_id": "11111111-1111-4111-8111-111111111111"},
        headers=intruder,
    )
    foreign = await client.patch(
        f"/api/v1/notes/{note['id']}",
        json={"folder_id": str(victim_folder["id"])},
        headers=intruder,
    )

    assert unknown.status_code == 404
    assert foreign.status_code == 404
    # La nota quedó como estaba: el 404 no aplicó una parte del PATCH.
    current = await client.get(f"/api/v1/notes/{note['id']}", headers=intruder)
    assert current.json()["folder_id"] is None


async def test_patch_unknown_or_foreign_note_is_404(client: httpx.AsyncClient) -> None:
    owner = await _register_and_login(client, "notes-edit-owner@example.com")
    intruder = await _register_and_login(client, "notes-edit-intruder@example.com")
    note = await _create_note(client, owner, "Privada", content="secreto")

    unknown = await client.patch(
        "/api/v1/notes/11111111-1111-4111-8111-111111111111",
        json={"title": "X"},
        headers=owner,
    )
    foreign = await client.patch(
        f"/api/v1/notes/{note['id']}", json={"title": "Robada"}, headers=intruder
    )

    assert unknown.status_code == 404
    assert foreign.status_code == 404
    unchanged = await client.get(f"/api/v1/notes/{note['id']}", headers=owner)
    assert unchanged.json()["title"] == "Privada"


# --- Borrado -----------------------------------------------------------------------------------


async def test_delete_note_removes_it_without_touching_its_folder(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "notes-delete@example.com")
    folder = await _create_folder(client, headers, "Research")
    note = await _create_note(client, headers, "Tesis", folder_id=str(folder["id"]))

    response = await client.delete(f"/api/v1/notes/{note['id']}", headers=headers)

    assert response.status_code == 204
    assert (
        await client.get(f"/api/v1/notes/{note['id']}", headers=headers)
    ).status_code == 404
    # La carpeta sigue existiendo y su conteo baja: borrar una nota es lo único que se borra.
    listing = await client.get("/api/v1/folders", headers=headers)
    assert listing.json()[0]["note_count"] == 0


async def test_delete_unknown_or_foreign_note_is_404(client: httpx.AsyncClient) -> None:
    owner = await _register_and_login(client, "notes-del-owner@example.com")
    intruder = await _register_and_login(client, "notes-del-intruder@example.com")
    note = await _create_note(client, owner, "Privada")

    unknown = await client.delete(
        "/api/v1/notes/11111111-1111-4111-8111-111111111111", headers=owner
    )
    foreign = await client.delete(f"/api/v1/notes/{note['id']}", headers=intruder)

    assert unknown.status_code == 404
    assert foreign.status_code == 404
    # Y la nota ajena sobrevive: el 404 no fue un borrado silencioso.
    assert (
        await client.get(f"/api/v1/notes/{note['id']}", headers=owner)
    ).status_code == 200
