"""Schemas de `POST /api/v1/ai/translate-financial` — el Traductor Financiero.

Es el "Explicar para Principiantes" del producto (Spec.md §4.2) disponible como operación suelta:
el usuario marca cualquier término o párrafo técnico —de una Ficha, de una alerta, de una
noticia— y recibe la versión en castellano llano.

La respuesta separa tres cosas que suelen venir mezcladas en una explicación:
  - `simple_explanation`: qué dice, sin jerga.
  - `analogy`: a qué se parece en la vida cotidiana. Va aparte porque una analogía es una ayuda
    para entender, no una afirmación sobre la empresa — mezclarlas dejaría al lector sin saber
    cuál de las dos frases es el dato.
  - `key_terms`: el glosario de los tecnicismos que aparecían, para que la próxima vez que los vea
    no necesite volver a traducir.
"""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field


class GlossaryEntry(BaseModel):
    """Un tecnicismo del texto original con su significado en llano."""

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    term: str
    plain_meaning: str


class FinancialTranslation(BaseModel):
    """Respuesta de `POST /api/v1/ai/translate-financial`.

    Siempre 200 con estructura válida (salvo 401/422): un entorno sin credenciales de IA devuelve
    `available=False` con su motivo en vez de un 503. El toggle "Explicar para Principiantes" del
    cliente puede así mostrar un aviso en línea, que es lo que corresponde a una ayuda opcional —
    un error de transporte lo haría parecer una falla de la pantalla que lo contiene.
    """

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    original_text: str
    simple_explanation: str | None = None
    analogy: str | None = None
    key_terms: list[GlossaryEntry] = Field(default_factory=list)

    available: bool = False
    served_from_cache: bool = False
    degradation_reason: str | None = None


class FinancialTranslationRequest(BaseModel):
    # strict=False (default) deliberado, igual que el resto de los schemas de request: valida JSON
    # externo de un request HTTP.
    model_config = ConfigDict(extra="forbid")

    text: str = Field(
        min_length=2,
        max_length=4000,
        description="El término, la frase o el párrafo técnico a traducir.",
    )
    context: str | None = Field(
        default=None,
        max_length=1000,
        description=(
            "De dónde salió el texto (ticker, título de la alerta, sección de la Ficha). Es "
            "opcional pero cambia mucho la calidad: 'múltiplo alto' se explica distinto si viene "
            "de una tecnológica que si viene de un banco."
        ),
    )
