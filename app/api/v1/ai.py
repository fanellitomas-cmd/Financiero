"""`POST /api/v1/ai/translate-financial` — el Traductor Financiero.

Router propio (`/ai`) y no una ruta más en `/chat`: el chat es una conversación con estado
implícito (una pregunta sobre un ticker, con contexto de mercado inyectado), y esto es una
transformación sin estado de un texto que el cliente ya tiene en pantalla. Meterlos juntos haría
que el "Explicar para Principiantes" arrastrase todo el armado de contexto del chat, que no
necesita.
"""

from __future__ import annotations

from fastapi import APIRouter

from app.api.deps import CurrentUser, FinancialTranslatorDep
from app.schemas.translation import FinancialTranslation, FinancialTranslationRequest

router = APIRouter(prefix="/ai", tags=["ai"])


@router.post(
    "/translate-financial",
    response_model=FinancialTranslation,
    summary="Traducir un texto financiero a lenguaje simple",
)
async def translate_financial(
    payload: FinancialTranslationRequest,
    # `current_user` antes que el servicio: FastAPI resuelve en orden de firma, y así un pedido sin
    # token corta con 401 sin revelar el estado de configuración del backend.
    current_user: CurrentUser,
    translator: FinancialTranslatorDep,
) -> FinancialTranslation:
    """Reescribe un término o un análisis técnico en castellano llano, con una analogía cotidiana y
    el glosario de los tecnicismos que aparecían.

    Siempre 200 con estructura válida: un entorno sin credenciales de IA devuelve `available=False`
    con su motivo, no un 503. El toggle "Explicar para Principiantes" es una ayuda opcional, y un
    error de transporte lo haría parecer una falla de la pantalla que lo contiene.

    El resultado se cachea por contenido (texto + contexto), así que el mismo término pedido por
    dos usuarios distintos gasta una sola llamada al modelo.
    """

    return await translator.translate(payload.text, context=payload.context)
