"""Tests de `/api/v1/notes/{id}/attachments` — capturas de gráficos y su capa de dibujo.

Los contratos que este módulo promete y que son fáciles de romper sin darse cuenta:

  1. **La imagen y el dibujo tienen ciclos de vida distintos.** Guardar una anotación reescribe unos
     cientos de bytes de JSON y NO toca el blob; si alguna vez el PUT empezara a regrabar la imagen,
     nada fallaría y cada edición costaría cientos de KB.
  2. **El listado no baja bytes.** Devuelve metadatos y una `image_url`; los píxeles se piden aparte.
     Si `image_bytes` dejara de estar diferida, abrir una nota con diez capturas bajaría megabytes sin
     que ningún test lo note salvo éste.
  3. **El alcance es el usuario Y la nota.** Un adjunto propio no se puede leer desde la URL de otra
     nota propia: sin ese filtro, el `note_id` de la ruta sería decorativo.
  4. **Un dibujo imposible se rechaza, no se guarda.** Una recta con tres puntos o un texto vacío se
     guardan sin error y rompen el canvas al releerlos, lejos de donde se originaron.
  5. **Borrar la nota se lleva sus adjuntos.** Acá el cascade SÍ corresponde — un adjunto sin su nota
     no tiene a dónde ir.
"""

from __future__ import annotations

import base64
import uuid
from typing import Any

import httpx
import pytest
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.note_attachment import NoteAttachment
from app.schemas.note_attachment import (
    MAX_IMAGE_BYTES,
    DrawingLayer,
    DrawingPoint,
    DrawingShape,
    NoteAttachmentCreate,
    ShapeKind,
)

# --- Fixtures de imagen ------------------------------------------------------------------------

# PNG mínimo válido: la firma de 8 bytes más un poco de relleno. El backend chequea la firma (no
# decodifica la imagen), así que esto es exactamente lo que valida.
PNG_BYTES = b"\x89PNG\r\n\x1a\n" + b"\x00\x01\x02\x03" * 16
JPEG_BYTES = b"\xff\xd8\xff\xe0" + b"\x10JFIF\x00" * 8
WEBP_BYTES = b"RIFF" + b"\x00\x00\x01\x00" + b"WEBP" + b"VP8 " * 4


def _b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode()


def _line(
    shape_id: str = "s1",
    *,
    color: str = "#22d3ee",
    points: list[tuple[float, float]] | None = None,
) -> dict[str, Any]:
    coords = points or [(0.1, 0.2), (0.8, 0.55)]
    return {
        "id": shape_id,
        "kind": "LINE",
        "points": [{"x": x, "y": y} for x, y in coords],
        "color": color,
        "stroke_width": 2.5,
    }


def _text(shape_id: str = "t1", text: str = "Resistencia") -> dict[str, Any]:
    return {
        "id": shape_id,
        "kind": "TEXT",
        "points": [{"x": 0.4, "y": 0.15}],
        "color": "#f59e0b",
        "text": text,
    }


def _upload_body(**overrides: Any) -> dict[str, Any]:
    body: dict[str, Any] = {
        "image_data": _b64(PNG_BYTES),
        "content_type": "image/png",
        "ticker": "NVDA",
        "caption": "Ruptura de la resistencia de 640",
        "source": "chart",
        "width": 1200,
        "height": 700,
        "drawing": {"version": 1, "shapes": [_line(), _text()]},
    }
    body.update(overrides)
    return body


# --- Helpers -----------------------------------------------------------------------------------


async def _register_and_login(client: httpx.AsyncClient, email: str) -> dict[str, str]:
    await client.post(
        "/api/v1/auth/register", json={"email": email, "password": "supersecreta1"}
    )
    login = await client.post(
        "/api/v1/auth/login", json={"email": email, "password": "supersecreta1"}
    )
    return {"Authorization": f"Bearer {login.json()['access_token']}"}


async def _create_note(
    client: httpx.AsyncClient, headers: dict[str, str], title: str = "Tesis NVDA"
) -> str:
    response = await client.post(
        "/api/v1/notes", json={"title": title, "ticker": "NVDA"}, headers=headers
    )
    assert response.status_code == 201, response.text
    note_id: str = response.json()["id"]
    return note_id


async def _upload(
    client: httpx.AsyncClient,
    headers: dict[str, str],
    note_id: str,
    **overrides: Any,
) -> dict[str, Any]:
    response = await client.post(
        f"/api/v1/notes/{note_id}/attachments",
        json=_upload_body(**overrides),
        headers=headers,
    )
    assert response.status_code == 201, response.text
    created: dict[str, Any] = response.json()
    return created


# --- Autenticación ----------------------------------------------------------------------------


async def test_attachments_require_authentication(client: httpx.AsyncClient) -> None:
    note = "11111111-1111-4111-8111-111111111111"

    assert (await client.get(f"/api/v1/notes/{note}/attachments")).status_code == 401
    assert (
        await client.post(f"/api/v1/notes/{note}/attachments", json=_upload_body())
    ).status_code == 401
    assert (
        await client.get(f"/api/v1/notes/{note}/attachments/{note}/image")
    ).status_code == 401


# --- Subida -----------------------------------------------------------------------------------


async def test_upload_returns_metadata_drawing_and_image_url(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "att-upload@example.com")
    note_id = await _create_note(client, headers)

    created = await _upload(client, headers, note_id)

    assert created["note_id"] == note_id
    assert created["ticker"] == "NVDA"
    assert created["content_type"] == "image/png"
    assert created["byte_size"] == len(PNG_BYTES)
    assert created["width"] == 1200
    assert created["height"] == 700
    assert created["caption"] == "Ruptura de la resistencia de 640"
    assert created["source"] == "chart"
    # El dibujo vuelve entero: el canvas lo necesita para pintar las anotaciones apenas carga.
    assert len(created["drawing"]["shapes"]) == 2
    assert created["drawing"]["version"] == 1
    # Los bytes NO viajan en la respuesta: se piden por la URL que arma el backend.
    assert "image_data" not in created
    assert "image_bytes" not in created
    assert (
        created["image_url"]
        == f"/api/v1/notes/{note_id}/attachments/{created['id']}/image"
    )


async def test_upload_accepts_a_data_uri_prefix(client: httpx.AsyncClient) -> None:
    """`canvas.toDataURL()` devuelve `data:image/png;base64,...`. Obligar al cliente a pelarlo sería
    un 422 por una diferencia que el servidor resuelve solo.
    """

    headers = await _register_and_login(client, "att-datauri@example.com")
    note_id = await _create_note(client, headers)

    created = await _upload(
        client,
        headers,
        note_id,
        image_data=f"data:image/png;base64,{_b64(PNG_BYTES)}",
    )

    assert created["byte_size"] == len(PNG_BYTES)


async def test_upload_without_drawing_starts_with_an_empty_layer(
    client: httpx.AsyncClient,
) -> None:
    """Pegar la captura primero y anotarla después es el flujo normal."""

    headers = await _register_and_login(client, "att-nodrawing@example.com")
    note_id = await _create_note(client, headers)

    response = await client.post(
        f"/api/v1/notes/{note_id}/attachments",
        json={"image_data": _b64(PNG_BYTES)},
        headers=headers,
    )

    assert response.status_code == 201
    assert response.json()["drawing"] == {"version": 1, "shapes": []}
    # Y los defaults quedan explícitos, no inventados.
    assert response.json()["content_type"] == "image/png"
    assert response.json()["ticker"] is None


async def test_upload_accepts_jpeg_and_webp(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "att-formats@example.com")
    note_id = await _create_note(client, headers)

    jpeg = await _upload(
        client,
        headers,
        note_id,
        image_data=_b64(JPEG_BYTES),
        content_type="image/jpeg",
    )
    webp = await _upload(
        client,
        headers,
        note_id,
        image_data=_b64(WEBP_BYTES),
        content_type="image/webp",
    )

    assert jpeg["content_type"] == "image/jpeg"
    assert webp["content_type"] == "image/webp"


async def test_upload_rejects_corrupt_base64(client: httpx.AsyncClient) -> None:
    """Un base64 roto es un error del request, no del servidor: tiene que ser 422 y no 500."""

    headers = await _register_and_login(client, "att-badb64@example.com")
    note_id = await _create_note(client, headers)

    response = await client.post(
        f"/api/v1/notes/{note_id}/attachments",
        json={"image_data": "no-es-base64-!!!"},
        headers=headers,
    )

    assert response.status_code == 422


async def test_upload_rejects_a_type_outside_the_whitelist(
    client: httpx.AsyncClient,
) -> None:
    """`image/svg+xml` se rechaza aunque sea una imagen: el endpoint de bytes reenvía el
    `Content-Type`, y un SVG servido desde el dominio de la app es un vector de scripting.
    """

    headers = await _register_and_login(client, "att-svg@example.com")
    note_id = await _create_note(client, headers)

    response = await client.post(
        f"/api/v1/notes/{note_id}/attachments",
        json={
            "image_data": _b64(b"<svg xmlns='http://www.w3.org/2000/svg'></svg>"),
            "content_type": "image/svg+xml",
        },
        headers=headers,
    )

    assert response.status_code == 422


async def test_upload_rejects_bytes_that_contradict_the_declared_type(
    client: httpx.AsyncClient,
) -> None:
    """Un adjunto que dice PNG y no lo es se guarda sin error y se ve como un ícono roto para
    siempre, con el fallo apareciendo lejos de la subida.
    """

    headers = await _register_and_login(client, "att-mismatch@example.com")
    note_id = await _create_note(client, headers)

    response = await client.post(
        f"/api/v1/notes/{note_id}/attachments",
        json={
            "image_data": _b64(b"esto no es una imagen"),
            "content_type": "image/png",
        },
        headers=headers,
    )

    assert response.status_code == 422

    # Y el desajuste cruzado también: bytes de JPEG declarados como PNG.
    crossed = await client.post(
        f"/api/v1/notes/{note_id}/attachments",
        json={"image_data": _b64(JPEG_BYTES), "content_type": "image/png"},
        headers=headers,
    )
    assert crossed.status_code == 422


async def test_upload_rejects_an_empty_or_oversized_image(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "att-size@example.com")
    note_id = await _create_note(client, headers)

    empty = await client.post(
        f"/api/v1/notes/{note_id}/attachments",
        json={"image_data": _b64(b"")},
        headers=headers,
    )
    huge = await client.post(
        f"/api/v1/notes/{note_id}/attachments",
        json={
            "image_data": _b64(
                b"\x89PNG\r\n\x1a\n" + b"\x00" * (MAX_IMAGE_BYTES + 1024)
            )
        },
        headers=headers,
    )

    assert empty.status_code == 422
    # El tope existe para que el error sea un 422 legible y no una fila de decenas de MB.
    assert huge.status_code == 422


async def test_upload_to_unknown_or_foreign_note_is_404(
    client: httpx.AsyncClient,
) -> None:
    owner = await _register_and_login(client, "att-owner@example.com")
    intruder = await _register_and_login(client, "att-intruder@example.com")
    note_id = await _create_note(client, owner)

    unknown = await client.post(
        "/api/v1/notes/11111111-1111-4111-8111-111111111111/attachments",
        json=_upload_body(),
        headers=owner,
    )
    foreign = await client.post(
        f"/api/v1/notes/{note_id}/attachments",
        json=_upload_body(),
        headers=intruder,
    )

    assert unknown.status_code == 404
    # 404 y no 403: distinguir "existe pero no es tuya" permitiría enumerar notas ajenas.
    assert foreign.status_code == 404


# --- Listado ----------------------------------------------------------------------------------


async def test_listing_returns_upload_order_without_bytes(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "att-list@example.com")
    note_id = await _create_note(client, headers)
    first = await _upload(client, headers, note_id, caption="Primera")
    second = await _upload(client, headers, note_id, caption="Segunda")

    response = await client.get(f"/api/v1/notes/{note_id}/attachments", headers=headers)

    assert response.status_code == 200
    items = response.json()
    # Orden de subida: es la secuencia que el usuario armó, y ordenar por última edición la
    # reordenaría cada vez que retoca una anotación.
    assert [item["id"] for item in items] == [first["id"], second["id"]]
    for item in items:
        assert "image_data" not in item
        assert item["byte_size"] == len(PNG_BYTES)
        assert item["image_url"].endswith("/image")


async def test_listing_an_empty_note_is_an_empty_list(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "att-empty@example.com")
    note_id = await _create_note(client, headers)

    response = await client.get(f"/api/v1/notes/{note_id}/attachments", headers=headers)

    assert response.status_code == 200
    assert response.json() == []


async def test_listing_only_shows_the_attachments_of_that_note(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "att-per-note@example.com")
    first_note = await _create_note(client, headers, "Nota A")
    second_note = await _create_note(client, headers, "Nota B")
    mine = await _upload(client, headers, first_note)
    await _upload(client, headers, second_note)

    response = await client.get(
        f"/api/v1/notes/{first_note}/attachments", headers=headers
    )

    assert [item["id"] for item in response.json()] == [mine["id"]]


async def test_listing_a_foreign_note_is_404(client: httpx.AsyncClient) -> None:
    owner = await _register_and_login(client, "att-list-owner@example.com")
    intruder = await _register_and_login(client, "att-list-intruder@example.com")
    note_id = await _create_note(client, owner)
    await _upload(client, owner, note_id)

    response = await client.get(
        f"/api/v1/notes/{note_id}/attachments", headers=intruder
    )

    assert response.status_code == 404


# --- Bytes de la imagen -------------------------------------------------------------------------


async def test_image_endpoint_returns_the_raw_bytes(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "att-image@example.com")
    note_id = await _create_note(client, headers)
    created = await _upload(client, headers, note_id)

    response = await client.get(created["image_url"], headers=headers)

    assert response.status_code == 200
    # Los bytes vuelven EXACTAMENTE como se subieron, no re-codificados en base64.
    assert response.content == PNG_BYTES
    assert response.headers["content-type"] == "image/png"
    # Inmutables: editar las anotaciones no cambia estos bytes, así que se pueden cachear fuerte.
    assert "immutable" in response.headers["cache-control"]
    assert "private" in response.headers["cache-control"]


async def test_image_of_a_foreign_attachment_is_404(client: httpx.AsyncClient) -> None:
    owner = await _register_and_login(client, "att-img-owner@example.com")
    intruder = await _register_and_login(client, "att-img-intruder@example.com")
    note_id = await _create_note(client, owner)
    created = await _upload(client, owner, note_id)

    response = await client.get(created["image_url"], headers=intruder)

    assert response.status_code == 404


async def test_an_attachment_cannot_be_read_through_another_note_of_the_same_user(
    client: httpx.AsyncClient,
) -> None:
    """El filtro por `note_id` no es redundante con el de usuario: sin él, el id de la nota en la
    ruta sería decorativo y cualquier adjunto propio se leería desde cualquier URL propia.
    """

    headers = await _register_and_login(client, "att-crossnote@example.com")
    first_note = await _create_note(client, headers, "Nota A")
    second_note = await _create_note(client, headers, "Nota B")
    created = await _upload(client, headers, first_note)

    wrong_url = f"/api/v1/notes/{second_note}/attachments/{created['id']}/image"
    assert (await client.get(wrong_url, headers=headers)).status_code == 404

    wrong_put = await client.put(
        f"/api/v1/notes/{second_note}/attachments/{created['id']}",
        json={"drawing": {"shapes": []}},
        headers=headers,
    )
    assert wrong_put.status_code == 404


# --- Actualización de la capa de dibujo ---------------------------------------------------------


async def test_put_replaces_the_whole_drawing_layer(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "att-put@example.com")
    note_id = await _create_note(client, headers)
    created = await _upload(client, headers, note_id)
    assert len(created["drawing"]["shapes"]) == 2

    response = await client.put(
        f"/api/v1/notes/{note_id}/attachments/{created['id']}",
        json={
            "drawing": {
                "version": 1,
                "shapes": [_line("nueva", color="#f87171"), _text("t2", "Soporte")],
            }
        },
        headers=headers,
    )

    assert response.status_code == 200
    shapes = response.json()["drawing"]["shapes"]
    # Reemplazo completo, no fusión: las formas viejas desaparecieron.
    assert [shape["id"] for shape in shapes] == ["nueva", "t2"]
    assert shapes[0]["color"] == "#f87171"
    assert shapes[1]["text"] == "Soporte"


async def test_put_with_an_empty_layer_erases_every_shape(
    client: httpx.AsyncClient,
) -> None:
    """Borrar la última anotación tiene que poder expresarse. Con semántica de parche, una capa vacía
    significaría "no cambies nada" y las formas quedarían vivas para siempre.
    """

    headers = await _register_and_login(client, "att-clear@example.com")
    note_id = await _create_note(client, headers)
    created = await _upload(client, headers, note_id)

    response = await client.put(
        f"/api/v1/notes/{note_id}/attachments/{created['id']}",
        json={"drawing": {"shapes": []}},
        headers=headers,
    )

    assert response.status_code == 200
    assert response.json()["drawing"]["shapes"] == []


async def test_put_does_not_touch_the_image(
    client: httpx.AsyncClient, db_session_factory: async_sessionmaker[AsyncSession]
) -> None:
    """La captura es inmutable: editar una flecha sobre una imagen de 800 KB reescribe unos cientos
    de bytes de JSON y nada más.
    """

    headers = await _register_and_login(client, "att-immutable@example.com")
    note_id = await _create_note(client, headers)
    created = await _upload(client, headers, note_id)

    await client.put(
        f"/api/v1/notes/{note_id}/attachments/{created['id']}",
        json={"drawing": {"shapes": [_line("otra")]}},
        headers=headers,
    )

    image = await client.get(created["image_url"], headers=headers)
    assert image.content == PNG_BYTES

    async with db_session_factory() as session:
        stored = await session.scalar(
            select(NoteAttachment.byte_size).where(
                NoteAttachment.id == uuid.UUID(created["id"])
            )
        )
    assert stored == len(PNG_BYTES)


async def test_put_updates_caption_and_can_clear_the_ticker(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "att-meta@example.com")
    note_id = await _create_note(client, headers)
    created = await _upload(client, headers, note_id)
    assert created["ticker"] == "NVDA"

    renamed = await client.put(
        f"/api/v1/notes/{note_id}/attachments/{created['id']}",
        json={"drawing": {"shapes": []}, "caption": "Otro título"},
        headers=headers,
    )
    assert renamed.json()["caption"] == "Otro título"
    # `ticker` no vino en el request: no se toca.
    assert renamed.json()["ticker"] == "NVDA"

    cleared = await client.put(
        f"/api/v1/notes/{note_id}/attachments/{created['id']}",
        json={"drawing": {"shapes": []}, "ticker": None},
        headers=headers,
    )
    # `null` EXPLÍCITO desvincula, igual que en el resto del Lab.
    assert cleared.json()["ticker"] is None


async def test_put_normalizes_the_ticker(client: httpx.AsyncClient) -> None:
    headers = await _register_and_login(client, "att-upper@example.com")
    note_id = await _create_note(client, headers)
    created = await _upload(client, headers, note_id)

    response = await client.put(
        f"/api/v1/notes/{note_id}/attachments/{created['id']}",
        json={"drawing": {"shapes": []}, "ticker": "amd"},
        headers=headers,
    )

    assert response.json()["ticker"] == "AMD"


async def test_put_on_unknown_or_foreign_attachment_is_404(
    client: httpx.AsyncClient,
) -> None:
    owner = await _register_and_login(client, "att-put-owner@example.com")
    intruder = await _register_and_login(client, "att-put-intruder@example.com")
    note_id = await _create_note(client, owner)
    created = await _upload(client, owner, note_id)

    unknown = await client.put(
        f"/api/v1/notes/{note_id}/attachments/11111111-1111-4111-8111-111111111111",
        json={"drawing": {"shapes": []}},
        headers=owner,
    )
    foreign = await client.put(
        f"/api/v1/notes/{note_id}/attachments/{created['id']}",
        json={"drawing": {"shapes": []}},
        headers=intruder,
    )

    assert unknown.status_code == 404
    assert foreign.status_code == 404


async def test_put_requires_the_drawing_field(client: httpx.AsyncClient) -> None:
    """`drawing` es obligatorio justamente porque el PUT reemplaza: omitirlo no puede significar
    "dejá el dibujo como está", que sería semántica de PATCH sobre un verbo que promete reemplazo.
    """

    headers = await _register_and_login(client, "att-put-required@example.com")
    note_id = await _create_note(client, headers)
    created = await _upload(client, headers, note_id)

    response = await client.put(
        f"/api/v1/notes/{note_id}/attachments/{created['id']}",
        json={"caption": "Solo el título"},
        headers=headers,
    )

    assert response.status_code == 422


# --- Validación de la capa de dibujo ------------------------------------------------------------


@pytest.mark.parametrize(
    ("shape", "reason"),
    [
        (
            {
                "id": "s",
                "kind": "LINE",
                "points": [{"x": 0.1, "y": 0.1}],
                "color": "#ffffff",
            },
            "una recta con un solo punto no tiene dirección",
        ),
        (
            {
                "id": "s",
                "kind": "RECT",
                "points": [
                    {"x": 0.1, "y": 0.1},
                    {"x": 0.5, "y": 0.5},
                    {"x": 0.9, "y": 0.9},
                ],
                "color": "#ffffff",
            },
            "un rectángulo con tres puntos no tiene esquinas",
        ),
        (
            {
                "id": "s",
                "kind": "FREEHAND",
                "points": [{"x": 0.1, "y": 0.1}],
                "color": "#ffffff",
            },
            "un trazo libre de un punto no es un trazo",
        ),
        (
            {
                "id": "s",
                "kind": "TEXT",
                "points": [{"x": 0.1, "y": 0.1}],
                "color": "#ffffff",
                "text": "   ",
            },
            "una anotación de texto vacía no dibuja nada",
        ),
        (
            {
                "id": "s",
                "kind": "LINE",
                "points": [{"x": 0.1, "y": 0.1}, {"x": 0.5, "y": 0.5}],
                "color": "#ffffff",
                "text": "sobra",
            },
            "un texto que nadie va a dibujar es peor que un 422",
        ),
        (
            {
                "id": "s",
                "kind": "LINE",
                "points": [{"x": 0.1, "y": 0.1}, {"x": 1.4, "y": 0.5}],
                "color": "#ffffff",
            },
            "una coordenada fuera de 0..1 cae afuera de la imagen",
        ),
        (
            {
                "id": "s",
                "kind": "LINE",
                "points": [{"x": 0.1, "y": 0.1}, {"x": 0.5, "y": 0.5}],
                "color": "rojo",
            },
            "un color que el cliente no puede parsear es una excepción en render",
        ),
        (
            {
                "id": "s",
                "kind": "TRIANGULO",
                "points": [{"x": 0.1, "y": 0.1}],
                "color": "#ffffff",
            },
            "una herramienta que el canvas no conoce no se puede dibujar",
        ),
    ],
)
async def test_invalid_shapes_are_rejected(
    client: httpx.AsyncClient, shape: dict[str, Any], reason: str
) -> None:
    headers = await _register_and_login(
        client, f"att-shape-{abs(hash(reason)) % 10000}@example.com"
    )
    note_id = await _create_note(client, headers)

    response = await client.post(
        f"/api/v1/notes/{note_id}/attachments",
        json={"image_data": _b64(PNG_BYTES), "drawing": {"shapes": [shape]}},
        headers=headers,
    )

    assert response.status_code == 422, reason


async def test_valid_shapes_of_every_kind_round_trip(
    client: httpx.AsyncClient,
) -> None:
    """Las seis herramientas del canvas se guardan y vuelven idénticas."""

    headers = await _register_and_login(client, "att-allkinds@example.com")
    note_id = await _create_note(client, headers)
    shapes = [
        {
            "id": "l",
            "kind": "LINE",
            "points": [{"x": 0.0, "y": 0.0}, {"x": 1.0, "y": 1.0}],
            "color": "#22d3ee",
            "stroke_width": 1.5,
        },
        {
            "id": "a",
            "kind": "ARROW",
            "points": [{"x": 0.2, "y": 0.8}, {"x": 0.6, "y": 0.3}],
            "color": "#10b981",
            "stroke_width": 3.0,
        },
        {
            "id": "r",
            "kind": "RECT",
            "points": [{"x": 0.1, "y": 0.1}, {"x": 0.4, "y": 0.4}],
            "color": "#f87171",
            "stroke_width": 2.0,
        },
        {
            "id": "e",
            "kind": "ELLIPSE",
            "points": [{"x": 0.5, "y": 0.5}, {"x": 0.7, "y": 0.7}],
            "color": "#818cf8",
            "stroke_width": 2.0,
        },
        {
            "id": "f",
            "kind": "FREEHAND",
            "points": [
                {"x": 0.1, "y": 0.2},
                {"x": 0.2, "y": 0.3},
                {"x": 0.3, "y": 0.25},
            ],
            "color": "#fbbf24",
            "stroke_width": 2.0,
        },
        {
            "id": "t",
            "kind": "TEXT",
            "points": [{"x": 0.5, "y": 0.05}],
            "color": "#94a3b8",
            "stroke_width": 2.0,
            "text": "Máximo histórico",
        },
    ]

    created = await _upload(
        client, headers, note_id, drawing={"version": 1, "shapes": shapes}
    )

    # El schema declara todos sus campos, así que las formas que no son TEXT vuelven con
    # `text: null` explícito. Es lo que hace que el cliente pueda re-mandar la respuesta tal cual.
    expected = [{"text": None, **shape} for shape in shapes]
    assert created["drawing"]["shapes"] == expected


async def test_a_transparent_color_with_alpha_is_accepted(
    client: httpx.AsyncClient,
) -> None:
    """`#aarrggbb` es el formato que usa Flutter para un resaltado semitransparente."""

    headers = await _register_and_login(client, "att-alpha@example.com")
    note_id = await _create_note(client, headers)

    created = await _upload(
        client,
        headers,
        note_id,
        drawing={"shapes": [_line("s", color="#4422d3ee")]},
    )

    assert created["drawing"]["shapes"][0]["color"] == "#4422d3ee"


@pytest.mark.parametrize("value", [float("nan"), float("inf"), float("-inf")])
def test_a_non_finite_coordinate_is_rejected(value: float) -> None:
    """Un NaN en una coordenada no rompe el guardado pero deja el canvas del cliente sin dibujar la
    capa entera. Lo cubren dos guardas a la vez: los límites `ge`/`le` y `allow_inf_nan=False`.
    """

    with pytest.raises(ValueError):
        DrawingShape.model_validate(
            {
                "id": "s",
                "kind": "LINE",
                "points": [{"x": value, "y": 0.1}, {"x": 0.5, "y": 0.5}],
                "color": "#ffffff",
            }
        )


def test_the_finiteness_guard_survives_a_looser_range() -> None:
    """La guarda declarativa (`allow_inf_nan=False`) no depende del rango: sigue rechazando `NaN`
    aunque alguien afloje los límites de la coordenada para una herramienta nueva.
    """

    assert DrawingPoint.model_config["allow_inf_nan"] is False


def test_the_layer_caps_the_number_of_shapes() -> None:
    """Sin tope, un bug del cliente podría empujar un JSON de decenas de MB en cada trazo."""

    too_many = [
        DrawingShape(
            id=f"s{index}",
            kind=ShapeKind.LINE,
            points=[{"x": 0.1, "y": 0.1}, {"x": 0.2, "y": 0.2}],  # type: ignore[list-item]
            color="#ffffff",
        )
        for index in range(600)
    ]

    with pytest.raises(ValueError, match="at most 500"):
        DrawingLayer(shapes=too_many)


def test_an_unknown_extra_field_is_rejected_not_silently_dropped() -> None:
    """`extra="forbid"`: un cliente que manda `strokeWidth` en camelCase tiene que enterarse, no ver
    su grosor descartado en silencio.
    """

    with pytest.raises(ValueError, match="strokeWidth"):
        DrawingShape.model_validate(
            {
                "id": "s",
                "kind": "LINE",
                "points": [{"x": 0.1, "y": 0.1}, {"x": 0.5, "y": 0.5}],
                "color": "#ffffff",
                "strokeWidth": 4,
            }
        )


def test_decoding_happens_during_validation_not_at_use_time() -> None:
    """Si la decodificación viviera en el servicio, un base64 corrupto sería una excepción a mitad de
    la escritura —o sea un 500— en vez del 422 que es.
    """

    with pytest.raises(ValueError, match="base64"):
        NoteAttachmentCreate(image_data="%%%no-base64%%%")

    valid = NoteAttachmentCreate(image_data=_b64(PNG_BYTES))
    assert valid.image == PNG_BYTES


# --- Borrado ------------------------------------------------------------------------------------


async def test_delete_removes_the_attachment_and_its_bytes(
    client: httpx.AsyncClient,
) -> None:
    headers = await _register_and_login(client, "att-delete@example.com")
    note_id = await _create_note(client, headers)
    created = await _upload(client, headers, note_id)

    response = await client.delete(
        f"/api/v1/notes/{note_id}/attachments/{created['id']}", headers=headers
    )

    assert response.status_code == 204
    assert (await client.get(created["image_url"], headers=headers)).status_code == 404
    listing = await client.get(f"/api/v1/notes/{note_id}/attachments", headers=headers)
    assert listing.json() == []


async def test_delete_of_unknown_or_foreign_attachment_is_404(
    client: httpx.AsyncClient,
) -> None:
    owner = await _register_and_login(client, "att-del-owner@example.com")
    intruder = await _register_and_login(client, "att-del-intruder@example.com")
    note_id = await _create_note(client, owner)
    created = await _upload(client, owner, note_id)

    unknown = await client.delete(
        f"/api/v1/notes/{note_id}/attachments/11111111-1111-4111-8111-111111111111",
        headers=owner,
    )
    foreign = await client.delete(
        f"/api/v1/notes/{note_id}/attachments/{created['id']}", headers=intruder
    )

    assert unknown.status_code == 404
    assert foreign.status_code == 404
    # Y el adjunto ajeno sobrevive: el 404 no fue un borrado silencioso.
    assert (await client.get(created["image_url"], headers=owner)).status_code == 200


async def test_deleting_the_note_deletes_its_attachments(
    client: httpx.AsyncClient, db_session_factory: async_sessionmaker[AsyncSession]
) -> None:
    """Acá el cascade SÍ corresponde, al revés que en las carpetas: un adjunto no significa nada sin
    su nota y no hay a dónde reparentarlo.
    """

    headers = await _register_and_login(client, "att-cascade@example.com")
    doomed = await _create_note(client, headers, "Se borra")
    survivor = await _create_note(client, headers, "Sobrevive")
    await _upload(client, headers, doomed)
    await _upload(client, headers, doomed)
    kept = await _upload(client, headers, survivor)

    assert (
        await client.delete(f"/api/v1/notes/{doomed}", headers=headers)
    ).status_code == 204

    async with db_session_factory() as session:
        remaining = list((await session.scalars(select(NoteAttachment.id))).all())
    assert len(remaining) == 1
    # La nota que no se tocó conserva su captura.
    assert (await client.get(kept["image_url"], headers=headers)).status_code == 200


# --- Robustez de lectura ------------------------------------------------------------------------


async def test_a_corrupt_stored_drawing_degrades_to_an_empty_layer(
    client: httpx.AsyncClient, db_session_factory: async_sessionmaker[AsyncSession]
) -> None:
    """La columna es JSON libre a nivel de base, así que una fila escrita por una versión anterior (o
    tocada a mano) puede no cumplir el contrato actual. La captura sigue sirviendo sin sus
    anotaciones; un 500 dejaría la nota entera inaccesible por un dibujo roto.
    """

    headers = await _register_and_login(client, "att-corrupt@example.com")
    note_id = await _create_note(client, headers)
    created = await _upload(client, headers, note_id)

    async with db_session_factory() as session:
        await session.execute(
            update(NoteAttachment)
            .where(NoteAttachment.id == uuid.UUID(created["id"]))
            .values(drawing_data={"version": 1, "shapes": [{"kind": "IMPOSIBLE"}]})
        )
        await session.commit()

    response = await client.get(f"/api/v1/notes/{note_id}/attachments", headers=headers)

    assert response.status_code == 200
    assert response.json()[0]["drawing"]["shapes"] == []
    # Y la imagen sigue siendo accesible: lo que se perdió son las anotaciones, no la captura.
    assert (await client.get(created["image_url"], headers=headers)).status_code == 200
