"""`POST /api/v1/chat` — buscador conversacional en lenguaje natural (Pantalla 2). Usa Gemini
directo con salida forzada a JSON (`ChatService`), no el pipeline de 5 nodos — es una consulta
puntual del usuario, no una alerta.
"""

from __future__ import annotations

from fastapi import APIRouter

from app.api.deps import ChatServiceDep, CurrentUser
from app.schemas.chat import ChatRequest, ChatResponse

router = APIRouter(prefix="/chat", tags=["chat"])


@router.post("", response_model=ChatResponse)
async def chat(
    payload: ChatRequest, current_user: CurrentUser, chat_service: ChatServiceDep
) -> ChatResponse:
    return await chat_service.answer(payload.prompt, payload.ticker)
