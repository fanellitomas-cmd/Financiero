"""Agrega todos los routers de la v1 de la API."""

from __future__ import annotations

from fastapi import APIRouter

from app.api.v1 import (
    ai,
    ai_lab,
    alerts,
    assets,
    auth,
    chat,
    corporate,
    devices,
    folders,
    internal,
    market,
    note_attachments,
    notes,
    portfolio_builder,
    tickers,
    watchlist,
    watchlist_alerts,
    watchlist_audit,
    websocket,
)

api_v1_router = APIRouter(prefix="/api/v1")
api_v1_router.include_router(auth.router)
# Las rutas literales de `/watchlist` van ANTES del ABM: FastAPI resuelve en orden de registro, y
# `PATCH /watchlist/{item_id}` declarado primero se comería `PATCH /watchlist/alerts/{rule_id}`
# intentando leer "alerts" como un UUID.
api_v1_router.include_router(watchlist_audit.router)
api_v1_router.include_router(watchlist_alerts.router)
api_v1_router.include_router(watchlist.router)
api_v1_router.include_router(devices.router)
api_v1_router.include_router(alerts.router)
api_v1_router.include_router(assets.router)
api_v1_router.include_router(chat.router)
api_v1_router.include_router(ai.router)
api_v1_router.include_router(ai_lab.router)
api_v1_router.include_router(corporate.router)
api_v1_router.include_router(portfolio_builder.router)
api_v1_router.include_router(market.router)
api_v1_router.include_router(tickers.router)
api_v1_router.include_router(folders.router)
# Los adjuntos van ANTES del ABM de notas, por la misma razón que las rutas literales de
# `/watchlist`: sus paths son más específicos (`/notes/{id}/attachments/...`) y registrarlos primero
# los deja fuera del alcance de cualquier ruta comodín que se agregue después a `notes.router`.
api_v1_router.include_router(note_attachments.router)
api_v1_router.include_router(notes.router)
api_v1_router.include_router(internal.router)
api_v1_router.include_router(websocket.router)
