"""Tests de `/api/v1/folders` — el árbol de carpetas del Investment Lab.

Lo que este bloque promete y que es fácil de romper sin darse cuenta:

  1. **El árbol no puede tener ciclos.** Mover una carpeta dentro de su propio descendiente es un
     `UPDATE` válido para la base y produce un subárbol que desaparece del listado, llevándose las
     notas de adentro. Se rechaza con 422.
  2. **Borrar una carpeta no borra notas.** Por defecto las notas suben a la raíz y las subcarpetas
     un nivel: el DELETE devuelve el resumen de eso justamente porque no es obvio. La cascada existe
     pero hay que pedirla.
  3. **Una carpeta ajena responde 404, no 403.** Un 403 distinguible permitiría enumerar carpetas de
     otros usuarios probando UUIDs.
  4. **`depth` y `path` los calcula el backend.** El cliente recibe una lista plana ya ordenada y no
     recalcula la jerarquía; si el orden o la profundidad se corren, la UI indenta mal.
"""

from __future__ import annotations

import httpx

from app.services.notes_service import MAX_FOLDER_DEPTH


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
    client: httpx.AsyncClient,
    headers: dict[str, str],
    name: str,
    parent_id: str | None = None,
) -> dict[str, object]:
    payload: dict[str, object] = {"name": name}
    if parent_id is not None:
        payload["parent_id"] = parent_id
    response = await client.post("/api/v1/folders", json=payload, headers=headers)
    assert response.status_code == 201, response.text
    created: dict[str, object] = response.json()
    return created


async def _create_note(
    client: httpx.AsyncClient,
    headers: dict[str, str],
    title: str,
    **extra: object,
) -> dict[str, object]:
    response = await client.post(
        "/api/v1/notes", json={"title": title, **extra}, headers=headers
    )
    assert response.status_code == 201, response.text
    created: dict[str, object] = response.json()
    return created


async def _chain(
    client: httpx.AsyncClient, headers: dict[str, str], levels: int, prefix: str = "N"
) -> list[dict[str, object]]:
    """Crea una cadena de `levels` carpetas anidadas (profundidades 0..levels-1)."""

    created: list[dict[str, object]] = []
    parent_id: str | None = None
    for index in range(levels):
        folder = await _create_folder(client, headers, f"{prefix}{index}", parent_id)
        created.append(folder)
        parent_id = str(folder["id"])
    return created


# --- Autenticación -----------------------------------------------------------------------------


async def test_folders_require_authentication(client: httpx.AsyncClient) -> None:
    assert (await client.get("/api/v1/folders")).status_code == 401
    assert (
        await client.post("/api/v1/folders", json={"name": "Research"})
    ).status_code == 401


# --- Creación ----------------------------------------------------------------------------------


async def test_create_root_folder_returns_computed_fields(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "folders-root@example.com")

    folder = await _create_folder(client, headers, "Research")

    assert folder["name"] == "Research"
    assert folder["parent_id"] is None
    # `depth`/`path`/conteos vienen ya calculados en la respuesta del POST: el cliente inserta la
    # carpeta en la lista que ya tiene sin recomputar nada.
    assert folder["depth"] == 0
    assert folder["path"] == "Research"
    assert folder["note_count"] == 0
    assert folder["subfolder_count"] == 0


async def test_create_subfolder_nests_and_updates_parent_counts(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "folders-nested@example.com")
    parent = await _create_folder(client, headers, "Research")

    child = await _create_folder(client, headers, "Semiconductores", str(parent["id"]))

    assert child["parent_id"] == parent["id"]
    assert child["depth"] == 1
    assert child["path"] == "Research / Semiconductores"

    listing = await client.get("/api/v1/folders", headers=headers)
    by_id = {item["id"]: item for item in listing.json()}
    assert by_id[parent["id"]]["subfolder_count"] == 1
    assert by_id[child["id"]]["subfolder_count"] == 0


async def test_create_folder_with_explicit_null_parent_lands_on_root(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "folders-null-parent@example.com")

    response = await client.post(
        "/api/v1/folders", json={"name": "Ideas", "parent_id": None}, headers=headers
    )

    assert response.status_code == 201
    assert response.json()["parent_id"] is None
    assert response.json()["depth"] == 0


async def test_create_folder_with_unknown_parent_is_404(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "folders-bad-parent@example.com")

    response = await client.post(
        "/api/v1/folders",
        json={"name": "Huérfana", "parent_id": "11111111-1111-4111-8111-111111111111"},
        headers=headers,
    )

    assert response.status_code == 404


async def test_cannot_create_subfolder_inside_another_users_folder(
    client: httpx.AsyncClient,
) -> None:
    """Sin este chequeo un usuario podría archivar carpetas dentro del árbol de otro y verlas
    desaparecer de su propio listado.
    """

    owner = await _register_and_login(client, "folders-owner@example.com")
    intruder = await _register_and_login(client, "folders-intruder@example.com")
    victim = await _create_folder(client, owner, "Privada")

    response = await client.post(
        "/api/v1/folders",
        json={"name": "Intrusa", "parent_id": str(victim["id"])},
        headers=intruder,
    )

    assert response.status_code == 404


async def test_duplicate_sibling_name_is_rejected_case_insensitively(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "folders-dupe@example.com")
    await _create_folder(client, headers, "Research")

    response = await client.post(
        "/api/v1/folders", json={"name": "research"}, headers=headers
    )

    assert response.status_code == 409
    assert "research" in response.json()["detail"].lower()


async def test_same_name_allowed_under_different_parents(
    client: httpx.AsyncClient,
) -> None:
    """La unicidad es por nivel, no global: "NVDA" puede existir bajo "Research" y bajo "Trades"."""

    headers = await _register_and_login(client, "folders-same-name@example.com")
    research = await _create_folder(client, headers, "Research")
    trades = await _create_folder(client, headers, "Trades")

    first = await _create_folder(client, headers, "NVDA", str(research["id"]))
    second = await _create_folder(client, headers, "NVDA", str(trades["id"]))

    assert first["path"] == "Research / NVDA"
    assert second["path"] == "Trades / NVDA"


async def test_another_user_can_reuse_a_folder_name(client: httpx.AsyncClient) -> None:
    first = await _register_and_login(client, "folders-user-a@example.com")
    second = await _register_and_login(client, "folders-user-b@example.com")
    await _create_folder(client, first, "Research")

    response = await client.post(
        "/api/v1/folders", json={"name": "Research"}, headers=second
    )

    assert response.status_code == 201


async def test_blank_and_oversized_names_are_rejected(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "folders-invalid-name@example.com")

    empty = await client.post("/api/v1/folders", json={"name": ""}, headers=headers)
    too_long = await client.post(
        "/api/v1/folders", json={"name": "x" * 121}, headers=headers
    )
    unknown_field = await client.post(
        "/api/v1/folders", json={"name": "Ok", "color": "rojo"}, headers=headers
    )

    assert empty.status_code == 422
    assert too_long.status_code == 422
    # `extra="forbid"`: un campo que el backend no conoce se rechaza en vez de descartarse en
    # silencio — un cliente que manda `colour` en vez de `color` tiene que enterarse.
    assert unknown_field.status_code == 422


# --- Jerarquía y listado -----------------------------------------------------------------------


async def test_listing_is_flat_depth_first_and_alphabetical(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "folders-order@example.com")
    # Se crean fuera de orden alfabético a propósito: el orden del listado tiene que venir del
    # nombre y de la jerarquía, no del orden de inserción.
    trades = await _create_folder(client, headers, "trades")
    research = await _create_folder(client, headers, "Research")
    await _create_folder(client, headers, "Semis", str(research["id"]))
    await _create_folder(client, headers, "Bancos", str(research["id"]))
    await _create_folder(client, headers, "Cerrados", str(trades["id"]))

    listing = await client.get("/api/v1/folders", headers=headers)

    assert listing.status_code == 200
    assert [(item["path"], item["depth"]) for item in listing.json()] == [
        # "Research" antes de "trades": el orden entre hermanas ignora mayúsculas.
        ("Research", 0),
        ("Research / Bancos", 1),
        ("Research / Semis", 1),
        ("trades", 0),
        ("trades / Cerrados", 1),
    ]


async def test_note_count_is_direct_children_only(client: httpx.AsyncClient) -> None:
    """`note_count` cuenta las notas de la carpeta y NO las de sus subcarpetas: es el número que va
    al lado del nombre, y un total recursivo haría que la carpeta padre mienta sobre lo que muestra
    al abrirla.
    """

    headers = await _register_and_login(client, "folders-note-count@example.com")
    parent = await _create_folder(client, headers, "Research")
    child = await _create_folder(client, headers, "Semis", str(parent["id"]))
    await _create_note(client, headers, "Tesis A", folder_id=str(parent["id"]))
    await _create_note(client, headers, "Tesis B", folder_id=str(parent["id"]))
    await _create_note(client, headers, "Tesis C", folder_id=str(child["id"]))
    await _create_note(client, headers, "Suelta")

    listing = await client.get("/api/v1/folders", headers=headers)
    by_id = {item["id"]: item for item in listing.json()}

    assert by_id[parent["id"]]["note_count"] == 2
    assert by_id[child["id"]]["note_count"] == 1


async def test_listing_only_shows_own_folders(client: httpx.AsyncClient) -> None:
    first = await _register_and_login(client, "folders-iso-a@example.com")
    second = await _register_and_login(client, "folders-iso-b@example.com")
    await _create_folder(client, first, "Research")
    await _create_folder(client, second, "Ajena")

    listing = await client.get("/api/v1/folders", headers=first)

    assert [item["name"] for item in listing.json()] == ["Research"]


async def test_depth_limit_blocks_a_deeper_chain(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "folders-depth@example.com")
    # Profundidades 0..MAX: la última carpeta ya está en el tope.
    chain = await _chain(client, headers, MAX_FOLDER_DEPTH + 1)
    assert chain[-1]["depth"] == MAX_FOLDER_DEPTH

    response = await client.post(
        "/api/v1/folders",
        json={"name": "UnaMás", "parent_id": str(chain[-1]["id"])},
        headers=headers,
    )

    assert response.status_code == 422
    assert str(MAX_FOLDER_DEPTH) in response.json()["detail"]


# --- PATCH: renombrar y mover ------------------------------------------------------------------


async def test_patch_renames_folder_and_updates_descendant_paths(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "folders-rename@example.com")
    parent = await _create_folder(client, headers, "Research")
    child = await _create_folder(client, headers, "Semis", str(parent["id"]))

    response = await client.patch(
        f"/api/v1/folders/{parent['id']}",
        json={"name": "Investigación"},
        headers=headers,
    )

    assert response.status_code == 200
    assert response.json()["path"] == "Investigación"
    listing = await client.get("/api/v1/folders", headers=headers)
    by_id = {item["id"]: item for item in listing.json()}
    # La ruta de la hija se recalcula sola porque se deriva del árbol, no se guarda.
    assert by_id[child["id"]]["path"] == "Investigación / Semis"


async def test_patch_moves_folder_into_another(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "folders-move@example.com")
    research = await _create_folder(client, headers, "Research")
    loose = await _create_folder(client, headers, "NVDA")

    response = await client.patch(
        f"/api/v1/folders/{loose['id']}",
        json={"parent_id": str(research["id"])},
        headers=headers,
    )

    assert response.status_code == 200
    assert response.json()["parent_id"] == research["id"]
    assert response.json()["depth"] == 1
    assert response.json()["path"] == "Research / NVDA"


async def test_explicit_null_parent_moves_folder_to_root(
    client: httpx.AsyncClient,
) -> None:
    """`parent_id: null` EXPLÍCITO es la única forma de sacar una subcarpeta de su padre: omitir el
    campo significa "dejarla donde está".
    """

    headers = await _register_and_login(client, "folders-to-root@example.com")
    parent = await _create_folder(client, headers, "Research")
    child = await _create_folder(client, headers, "Semis", str(parent["id"]))

    response = await client.patch(
        f"/api/v1/folders/{child['id']}", json={"parent_id": None}, headers=headers
    )

    assert response.status_code == 200
    assert response.json()["parent_id"] is None
    assert response.json()["depth"] == 0
    assert response.json()["path"] == "Semis"


async def test_omitting_parent_id_keeps_the_folder_where_it_is(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "folders-keep-parent@example.com")
    parent = await _create_folder(client, headers, "Research")
    child = await _create_folder(client, headers, "Semis", str(parent["id"]))

    response = await client.patch(
        f"/api/v1/folders/{child['id']}",
        json={"name": "Semiconductores"},
        headers=headers,
    )

    assert response.status_code == 200
    assert response.json()["parent_id"] == parent["id"]
    assert response.json()["path"] == "Research / Semiconductores"


async def test_moving_a_folder_into_itself_is_rejected(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "folders-self-cycle@example.com")
    folder = await _create_folder(client, headers, "Research")

    response = await client.patch(
        f"/api/v1/folders/{folder['id']}",
        json={"parent_id": str(folder["id"])},
        headers=headers,
    )

    assert response.status_code == 422


async def test_moving_a_folder_into_its_own_descendant_is_rejected(
    client: httpx.AsyncClient,
) -> None:
    """El caso que la base aceptaría sin protestar y que dejaría el subárbol invisible con sus notas
    adentro.
    """

    headers = await _register_and_login(client, "folders-cycle@example.com")
    chain = await _chain(client, headers, 3)

    response = await client.patch(
        f"/api/v1/folders/{chain[0]['id']}",
        json={"parent_id": str(chain[2]["id"])},
        headers=headers,
    )

    assert response.status_code == 422
    # El árbol queda intacto: el rechazo no dejó a medias ningún movimiento.
    listing = await client.get("/api/v1/folders", headers=headers)
    assert [item["depth"] for item in listing.json()] == [0, 1, 2]


async def test_move_is_rejected_when_the_subtree_would_exceed_the_depth_limit(
    client: httpx.AsyncClient,
) -> None:
    """Se valida la altura del SUBÁRBOL y no solo la de la carpeta movida: arrastrar dos niveles de
    hijas a un padre profundo pasa el tope aunque la carpeta movida sola entrara.
    """

    headers = await _register_and_login(client, "folders-subtree-depth@example.com")
    deep = await _chain(client, headers, MAX_FOLDER_DEPTH - 1, prefix="D")
    movable = await _create_folder(client, headers, "M0")
    middle = await _create_folder(client, headers, "M1", str(movable["id"]))
    await _create_folder(client, headers, "M2", str(middle["id"]))

    # `deep[-1]` está en profundidad MAX-2; con la altura 2 del subárbol el total daría MAX+1.
    too_deep = await client.patch(
        f"/api/v1/folders/{movable['id']}",
        json={"parent_id": str(deep[-1]["id"])},
        headers=headers,
    )
    assert too_deep.status_code == 422

    # Un nivel más arriba sí entra exactamente en el tope.
    fits = await client.patch(
        f"/api/v1/folders/{movable['id']}",
        json={"parent_id": str(deep[-2]["id"])},
        headers=headers,
    )
    assert fits.status_code == 200
    assert fits.json()["depth"] == MAX_FOLDER_DEPTH - 2


async def test_rename_colliding_with_a_sibling_is_rejected(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "folders-rename-clash@example.com")
    await _create_folder(client, headers, "Research")
    other = await _create_folder(client, headers, "Trades")

    response = await client.patch(
        f"/api/v1/folders/{other['id']}", json={"name": "Research"}, headers=headers
    )

    assert response.status_code == 409


async def test_move_colliding_with_a_sibling_is_rejected(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "folders-move-clash@example.com")
    research = await _create_folder(client, headers, "Research")
    await _create_folder(client, headers, "NVDA", str(research["id"]))
    loose = await _create_folder(client, headers, "NVDA")

    response = await client.patch(
        f"/api/v1/folders/{loose['id']}",
        json={"parent_id": str(research["id"])},
        headers=headers,
    )

    assert response.status_code == 409


async def test_renaming_a_folder_to_its_own_name_is_allowed(
    client: httpx.AsyncClient,
) -> None:
    """La carpeta se excluye del chequeo de unicidad: un PATCH idempotente no puede chocar consigo
    mismo.
    """

    headers = await _register_and_login(client, "folders-noop-rename@example.com")
    folder = await _create_folder(client, headers, "Research")

    response = await client.patch(
        f"/api/v1/folders/{folder['id']}", json={"name": "Research"}, headers=headers
    )

    assert response.status_code == 200


async def test_patch_unknown_or_foreign_folder_is_404(
    client: httpx.AsyncClient,
) -> None:
    owner = await _register_and_login(client, "folders-patch-owner@example.com")
    intruder = await _register_and_login(client, "folders-patch-intruder@example.com")
    folder = await _create_folder(client, owner, "Privada")

    unknown = await client.patch(
        "/api/v1/folders/11111111-1111-4111-8111-111111111111",
        json={"name": "X"},
        headers=owner,
    )
    foreign = await client.patch(
        f"/api/v1/folders/{folder['id']}", json={"name": "Robada"}, headers=intruder
    )

    assert unknown.status_code == 404
    # 404 y no 403: distinguir "existe pero no es tuya" permitiría enumerar carpetas ajenas.
    assert foreign.status_code == 404


async def test_moving_into_a_foreign_folder_is_404(client: httpx.AsyncClient) -> None:
    owner = await _register_and_login(client, "folders-move-owner@example.com")
    intruder = await _register_and_login(client, "folders-move-intruder@example.com")
    victim = await _create_folder(client, owner, "Privada")
    mine = await _create_folder(client, intruder, "Mía")

    response = await client.patch(
        f"/api/v1/folders/{mine['id']}",
        json={"parent_id": str(victim["id"])},
        headers=intruder,
    )

    assert response.status_code == 404


# --- DELETE: reparentar por defecto, cascada si se pide ----------------------------------------


async def test_delete_reparents_subfolders_and_detaches_notes(
    client: httpx.AsyncClient,
) -> None:
    """El default no pierde nada: las notas van a la raíz y las subcarpetas suben un nivel."""

    headers = await _register_and_login(client, "folders-delete-safe@example.com")
    root = await _create_folder(client, headers, "Lab")
    doomed = await _create_folder(client, headers, "Research", str(root["id"]))
    kept_a = await _create_folder(client, headers, "Semis", str(doomed["id"]))
    kept_b = await _create_folder(client, headers, "Bancos", str(doomed["id"]))
    note = await _create_note(
        client, headers, "Tesis NVDA", folder_id=str(doomed["id"])
    )
    grandchild_note = await _create_note(
        client, headers, "Nota de Semis", folder_id=str(kept_a["id"])
    )

    response = await client.delete(f"/api/v1/folders/{doomed['id']}", headers=headers)

    assert response.status_code == 200
    assert response.json() == {
        "deleted_folder_id": doomed["id"],
        "cascade": False,
        "reparented_folders": 2,
        "detached_notes": 1,
        "deleted_folders": 0,
        "deleted_notes": 0,
    }

    listing = await client.get("/api/v1/folders", headers=headers)
    by_id = {item["id"]: item for item in listing.json()}
    assert doomed["id"] not in by_id
    # Las hijas suben al abuelo, no a la raíz: conservan el contexto que tenían.
    assert by_id[kept_a["id"]]["parent_id"] == root["id"]
    assert by_id[kept_b["id"]]["parent_id"] == root["id"]
    assert by_id[kept_a["id"]]["path"] == "Lab / Semis"

    detached = await client.get(f"/api/v1/notes/{note['id']}", headers=headers)
    assert detached.status_code == 200
    assert detached.json()["folder_id"] is None
    # La nota de la subcarpeta ni se movió: su carpeta sigue existiendo.
    still_filed = await client.get(
        f"/api/v1/notes/{grandchild_note['id']}", headers=headers
    )
    assert still_filed.json()["folder_id"] == kept_a["id"]


async def test_delete_root_folder_promotes_children_to_root(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "folders-delete-root@example.com")
    parent = await _create_folder(client, headers, "Research")
    child = await _create_folder(client, headers, "Semis", str(parent["id"]))

    response = await client.delete(f"/api/v1/folders/{parent['id']}", headers=headers)

    assert response.status_code == 200
    listing = await client.get("/api/v1/folders", headers=headers)
    assert len(listing.json()) == 1
    promoted = listing.json()[0]
    assert promoted["id"] == child["id"]
    assert promoted["parent_id"] is None
    assert promoted["depth"] == 0


async def test_reparented_children_are_renamed_on_name_clash(
    client: httpx.AsyncClient,
) -> None:
    """Un choque de nombres entre otras dos carpetas no puede bloquear un borrado que el usuario ya
    pidió: la hija que sube se renombra con un sufijo.
    """

    headers = await _register_and_login(client, "folders-delete-clash@example.com")
    doomed = await _create_folder(client, headers, "Research")
    child = await _create_folder(client, headers, "NVDA", str(doomed["id"]))
    await _create_folder(client, headers, "NVDA")

    response = await client.delete(f"/api/v1/folders/{doomed['id']}", headers=headers)

    assert response.status_code == 200
    listing = await client.get("/api/v1/folders", headers=headers)
    by_id = {item["id"]: item for item in listing.json()}
    assert by_id[child["id"]]["name"] == "NVDA (2)"
    assert sorted(item["name"] for item in listing.json()) == ["NVDA", "NVDA (2)"]


async def test_cascade_delete_removes_the_subtree_and_its_notes(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "folders-cascade@example.com")
    doomed = await _create_folder(client, headers, "Research")
    child = await _create_folder(client, headers, "Semis", str(doomed["id"]))
    grandchild = await _create_folder(client, headers, "NVDA", str(child["id"]))
    survivor_folder = await _create_folder(client, headers, "Trades")

    doomed_note = await _create_note(
        client, headers, "Tesis", folder_id=str(doomed["id"])
    )
    deep_note = await _create_note(
        client, headers, "Nota profunda", folder_id=str(grandchild["id"])
    )
    survivor_note = await _create_note(
        client, headers, "Nota de Trades", folder_id=str(survivor_folder["id"])
    )
    root_note = await _create_note(client, headers, "Nota suelta")

    response = await client.delete(
        f"/api/v1/folders/{doomed['id']}", params={"cascade": True}, headers=headers
    )

    assert response.status_code == 200
    assert response.json() == {
        "deleted_folder_id": doomed["id"],
        "cascade": True,
        "reparented_folders": 0,
        "detached_notes": 0,
        # Las dos descendientes; la carpeta pedida va aparte en `deleted_folder_id`.
        "deleted_folders": 2,
        "deleted_notes": 2,
    }

    listing = await client.get("/api/v1/folders", headers=headers)
    assert [item["name"] for item in listing.json()] == ["Trades"]

    for gone in (doomed_note, deep_note):
        assert (
            await client.get(f"/api/v1/notes/{gone['id']}", headers=headers)
        ).status_code == 404
    for kept in (survivor_note, root_note):
        assert (
            await client.get(f"/api/v1/notes/{kept['id']}", headers=headers)
        ).status_code == 200


async def test_cascade_delete_of_a_leaf_reports_zero_counts(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "folders-cascade-leaf@example.com")
    folder = await _create_folder(client, headers, "Vacía")

    response = await client.delete(
        f"/api/v1/folders/{folder['id']}", params={"cascade": True}, headers=headers
    )

    assert response.status_code == 200
    assert response.json()["deleted_folders"] == 0
    assert response.json()["deleted_notes"] == 0


async def test_delete_unknown_or_foreign_folder_is_404(
    client: httpx.AsyncClient,
) -> None:
    owner = await _register_and_login(client, "folders-del-owner@example.com")
    intruder = await _register_and_login(client, "folders-del-intruder@example.com")
    folder = await _create_folder(client, owner, "Privada")

    unknown = await client.delete(
        "/api/v1/folders/11111111-1111-4111-8111-111111111111", headers=owner
    )
    foreign = await client.delete(
        f"/api/v1/folders/{folder['id']}", params={"cascade": True}, headers=intruder
    )

    assert unknown.status_code == 404
    assert foreign.status_code == 404
    # Y la carpeta ajena sigue en pie: el 404 no fue un borrado silencioso.
    listing = await client.get("/api/v1/folders", headers=owner)
    assert [item["id"] for item in listing.json()] == [folder["id"]]


async def test_deleting_a_folder_does_not_touch_another_users_tree(
    client: httpx.AsyncClient,
) -> None:
    """Las hijas y notas que se reparentan se buscan filtrando por `user_id`: sin ese filtro, dos
    usuarios con el mismo UUID de carpeta se pisarían.
    """

    first = await _register_and_login(client, "folders-del-iso-a@example.com")
    second = await _register_and_login(client, "folders-del-iso-b@example.com")
    mine = await _create_folder(client, first, "Research")
    theirs = await _create_folder(client, second, "Research")
    await _create_note(client, second, "Ajena", folder_id=str(theirs["id"]))

    await client.delete(f"/api/v1/folders/{mine['id']}", headers=first)

    listing = await client.get("/api/v1/folders", headers=second)
    assert [item["id"] for item in listing.json()] == [theirs["id"]]
    assert listing.json()[0]["note_count"] == 1
