"""Schemas de `/api/v1/notes/{id}/attachments` — capturas de gráficos y su capa de dibujo.

Dos decisiones de contrato que sostienen todo el módulo:

  1. **Las coordenadas del dibujo son NORMALIZADAS (0..1), no píxeles.** La misma captura se muestra
     a 320px en un teléfono y a 900px en el panel del escritorio; con coordenadas absolutas, una
     flecha que apunta a un máximo de precio apuntaría al aire en la otra pantalla. Normalizar deja
     el trazo pegado al punto del gráfico que el usuario marcó, en cualquier tamaño.
  2. **La forma se valida por tipo.** Una recta con tres puntos, o un texto sin texto, son datos que
     ningún cliente puede dibujar: aceptarlos guardaría basura que rompe el canvas al releerla, y el
     error aparecería a la semana siguiente, lejos de donde se originó.

La imagen viaja en base64 porque el cuerpo es JSON —el dibujo tiene que llegar en el mismo request
que la captura, y un `multipart` con un campo JSON adentro es incómodo desde el cliente—, pero se
**guarda en crudo**: conservar el base64 desperdiciaría un 33% del espacio para siempre.
"""

from __future__ import annotations

import base64
import binascii
from datetime import datetime
from enum import Enum
from uuid import UUID

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    PrivateAttr,
    field_validator,
    model_validator,
)

# Tope de la imagen decodificada. Una captura de un chart ronda los 200-600 KB; 4 MB deja lugar de
# sobra para una pantalla retina completa y corta antes de que una subida por error llene la tabla.
MAX_IMAGE_BYTES = 4 * 1024 * 1024

# El base64 infla ~33%, más el margen del `data:` URI que algunos clientes anteponen.
_MAX_ENCODED_LENGTH = (MAX_IMAGE_BYTES * 4) // 3 + 1024

# Tope de formas por capa. Un dibujo a mano alzada largo puede tener cientos de puntos pero no miles
# de formas; sin tope, un bug del cliente podría empujar un JSON de decenas de MB.
MAX_SHAPES = 500

# Tope de puntos de un trazo libre. Es lo que acota el tamaño de la capa: 2000 puntos son un garabato
# muy largo, y el cliente puede simplificar antes de mandar.
MAX_POINTS = 2000

# Formatos aceptados. Lista blanca y no "cualquier image/*": el endpoint que devuelve los bytes
# reenvía este valor como `Content-Type`, y aceptar `image/svg+xml` convertiría el adjunto en un
# vector de scripting sobre el dominio de la app.
ALLOWED_CONTENT_TYPES = frozenset({"image/png", "image/jpeg", "image/webp"})


def _matches_signature(raw: bytes, content_type: str) -> bool:
    """¿Los bytes son realmente del formato declarado?

    Se chequea la firma y no se confía en el `content_type` del cliente porque el desajuste es
    permanente y silencioso: un adjunto que dice `image/png` y no lo es se guarda sin error y se
    muestra como un ícono roto para siempre, con el fallo apareciendo semanas después de la subida y
    lejos de donde se originó. Además el endpoint de bytes reenvía ese header, así que dejar que la
    declaración y el contenido difieran habilita que el navegador olfatee algo distinto de una imagen.
    """

    match content_type:
        case "image/png":
            return raw.startswith(b"\x89PNG\r\n\x1a\n")
        case "image/jpeg":
            return raw.startswith(b"\xff\xd8\xff")
        case "image/webp":
            # RIFF <4 bytes de tamaño> WEBP
            return len(raw) >= 12 and raw[:4] == b"RIFF" and raw[8:12] == b"WEBP"
        case _:  # pragma: no cover - la lista blanca ya lo filtró
            return False


class ShapeKind(str, Enum):
    """Herramientas del canvas. Cada una define cuántos puntos necesita, y esa es la validación."""

    LINE = "LINE"
    ARROW = "ARROW"
    RECT = "RECT"
    ELLIPSE = "ELLIPSE"
    FREEHAND = "FREEHAND"
    TEXT = "TEXT"


class DrawingPoint(BaseModel):
    """Un punto en coordenadas normalizadas: (0,0) es la esquina superior izquierda de la imagen y
    (1,1) la inferior derecha.
    """

    # `allow_inf_nan=False` es redundante HOY —los límites `ge`/`le` ya rechazan `NaN` e `inf`— y
    # está igual porque expresa la intención por separado del rango: si mañana alguien permite
    # coordenadas fuera de 0..1 para una herramienta nueva, un `NaN` seguiría rechazado en vez de
    # colarse y dejar el canvas del cliente sin dibujar la capa entera.
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)

    x: float = Field(ge=0, le=1)
    y: float = Field(ge=0, le=1)


class DrawingShape(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # Id del lado del cliente: es lo que le permite editar o borrar una forma puntual sin reenviar la
    # capa entera desde cero y sin que el servidor tenga que devolverle ids nuevos.
    id: str = Field(min_length=1, max_length=64)

    kind: ShapeKind
    points: list[DrawingPoint] = Field(min_length=1, max_length=MAX_POINTS)

    # `#rrggbb` o `#aarrggbb`. Se valida el formato porque este valor termina en un parser de color
    # del cliente, donde una cadena arbitraria es una excepción en tiempo de render.
    color: str = Field(pattern=r"^#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")

    stroke_width: float = Field(default=2.0, gt=0, le=64)

    # Solo para `TEXT`. Se acota porque una anotación sobre un gráfico es una etiqueta, no un párrafo.
    text: str | None = Field(default=None, max_length=280)

    @model_validator(mode="after")
    def _check_arity(self) -> DrawingShape:
        """Cada herramienta necesita una cantidad concreta de puntos.

        Se valida acá y no en el cliente porque es la regla que decide si la forma se puede dibujar:
        una `LINE` con un solo punto no tiene dirección, y un `RECT` con tres no tiene esquinas. Una
        capa con una forma así se guarda sin error y explota al releerla.
        """

        count = len(self.points)
        expected = {
            ShapeKind.LINE: 2,
            ShapeKind.ARROW: 2,
            ShapeKind.RECT: 2,
            ShapeKind.ELLIPSE: 2,
            ShapeKind.TEXT: 1,
        }.get(self.kind)

        if expected is not None and count != expected:
            raise ValueError(
                f"Una forma {self.kind.value} necesita exactamente {expected} "
                f"{'punto' if expected == 1 else 'puntos'}, llegaron {count}."
            )
        if self.kind is ShapeKind.FREEHAND and count < 2:
            raise ValueError("Un trazo libre necesita al menos 2 puntos.")

        if self.kind is ShapeKind.TEXT:
            if self.text is None or not self.text.strip():
                raise ValueError("Una anotación de texto no puede estar vacía.")
        elif self.text is not None:
            # Se rechaza en vez de ignorarlo: un texto que el cliente cree haber guardado y que nadie
            # va a dibujar es peor que un 422.
            raise ValueError(
                f"El campo `text` solo aplica a las formas TEXT, no a {self.kind.value}."
            )

        return self


class DrawingLayer(BaseModel):
    """La capa vectorial completa de un adjunto.

    Se manda y se guarda SIEMPRE entera: el canvas conoce su estado completo, y un protocolo de
    parches por forma agregaría resolución de conflictos para un recurso que edita un solo usuario en
    una sola pantalla.
    """

    model_config = ConfigDict(extra="forbid")

    # Versión del formato. Existe desde el día uno para que, cuando aparezca una herramienta nueva, un
    # cliente viejo pueda decir "esta capa la dibujó una versión que no entiendo" en vez de dibujar
    # una parte y callarse el resto.
    version: int = Field(default=1, ge=1, le=100)

    shapes: list[DrawingShape] = Field(default_factory=list, max_length=MAX_SHAPES)

    @property
    def is_empty(self) -> bool:
        return not self.shapes


class NoteAttachmentCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # Base64 de la imagen. Se acepta con o sin el prefijo `data:image/png;base64,` que anteponen
    # `canvas.toDataURL()` y varios pickers: obligar al cliente a pelarlo sería un 422 por una
    # diferencia que el servidor puede resolver solo.
    image_data: str = Field(min_length=4, max_length=_MAX_ENCODED_LENGTH)

    content_type: str = Field(default="image/png", max_length=64)
    ticker: str | None = Field(default=None, min_length=1, max_length=20)
    caption: str | None = Field(default=None, max_length=300)
    source: str | None = Field(default=None, max_length=64)
    width: int | None = Field(default=None, gt=0, le=20000)
    height: int | None = Field(default=None, gt=0, le=20000)

    # Un adjunto puede subirse sin dibujo: primero se pega la captura y después se anota.
    drawing: DrawingLayer = Field(default_factory=DrawingLayer)

    @field_validator("content_type")
    @classmethod
    def _known_type(cls, value: str) -> str:
        normalized = value.strip().lower()
        if normalized not in ALLOWED_CONTENT_TYPES:
            raise ValueError(
                "Formato no soportado. Se aceptan "
                f"{', '.join(sorted(ALLOWED_CONTENT_TYPES))}."
            )
        return normalized

    @field_validator("ticker")
    @classmethod
    def _upper(cls, value: str | None) -> str | None:
        return value.strip().upper() if value else None

    # Los bytes ya decodificados. Privado porque el que vale es el resultado del validador, no una
    # decodificación que cada llamador pueda repetir con otros criterios.
    _decoded: bytes = PrivateAttr(default=b"")

    @model_validator(mode="after")
    def _decode(self) -> NoteAttachmentCreate:
        """Decodifica y verifica la imagen DURANTE la validación del request.

        Va acá y no en el servicio para que un base64 corrupto sea un 422 —que es exactamente lo que
        es— en vez de una excepción a mitad de la escritura, que llegaría al cliente como un 500 sin
        decirle qué mandó mal. Los validadores de campo ya corrieron, así que `content_type` está
        normalizado y pasó por la lista blanca.
        """

        self._decoded = self._decode_image_data()
        return self

    @property
    def image(self) -> bytes:
        """Los bytes crudos de la imagen, listos para guardar."""

        return self._decoded

    def _decode_image_data(self) -> bytes:
        payload = self.image_data.strip()
        # `data:image/png;base64,iVBOR...` — se descarta el encabezado y se usa el `content_type`
        # declarado, que ya pasó por la lista blanca. Confiar en el del URI dejaría entrar un tipo
        # que el validador rechazó.
        if payload.startswith("data:"):
            _, _, payload = payload.partition(",")

        try:
            raw = base64.b64decode(payload, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise ValueError("La imagen no es base64 válido.") from exc

        if not raw:
            raise ValueError("La imagen está vacía.")
        if len(raw) > MAX_IMAGE_BYTES:
            raise ValueError(
                f"La imagen supera el máximo de {MAX_IMAGE_BYTES // (1024 * 1024)} MB."
            )
        if not _matches_signature(raw, self.content_type):
            raise ValueError(
                f"Los bytes no corresponden a un {self.content_type}. "
                "Revisá el formato declarado."
            )
        return raw


class NoteAttachmentUpdate(BaseModel):
    """PUT de la capa de dibujo.

    Es un PUT y no un PATCH porque el canvas manda su estado completo: mandar media capa y esperar
    que el servidor la fusione con la anterior dejaría las formas borradas vivas para siempre.

    Los metadatos (`caption`, `ticker`) sí son opcionales y se comportan como un PATCH; para
    desvincular el símbolo hay que mandar `null` explícito, igual que en el resto del Lab.
    """

    model_config = ConfigDict(extra="forbid")

    drawing: DrawingLayer
    caption: str | None = Field(default=None, max_length=300)
    ticker: str | None = Field(default=None, min_length=1, max_length=20)

    @field_validator("ticker")
    @classmethod
    def _upper(cls, value: str | None) -> str | None:
        return value.strip().upper() if value else None


class NoteAttachmentRead(BaseModel):
    """Un adjunto SIN sus bytes.

    La imagen se pide aparte (`GET .../{id}/image`) y por eso este schema no la incluye: una nota con
    diez capturas devolvería decenas de megabytes en base64 cada vez que se abre, casi todos para
    miniaturas que el navegador ya tiene cacheadas.
    """

    model_config = ConfigDict(strict=True, extra="forbid")

    id: UUID
    note_id: UUID
    ticker: str | None
    content_type: str
    byte_size: int = Field(ge=0)
    width: int | None
    height: int | None
    caption: str | None
    source: str | None

    # La capa vectorial sí viaja entera: son cientos de bytes y el canvas la necesita para dibujar
    # las anotaciones encima de la imagen apenas ésta carga.
    drawing: DrawingLayer

    # URL relativa de los bytes. La arma el backend en vez de dejar que el cliente la concatene: si
    # la ruta cambia, los clientes viejos siguen funcionando.
    image_url: str

    created_at: datetime
    updated_at: datetime

    @property
    def shape_count(self) -> int:
        return len(self.drawing.shapes)
