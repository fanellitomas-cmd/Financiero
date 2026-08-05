"""Agrega todos los routers de la v1 de la API."""

from __future__ import annotations

from fastapi import APIRouter

from app.api.v1 import (
    alerts,
    assets,
    auth,
    chat,
    devices,
    internal,
    market,
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
api_v1_router.include_router(market.router)
api_v1_router.include_router(tickers.router)
api_v1_router.include_router(internal.router)
api_v1_router.include_router(websocket.router)
