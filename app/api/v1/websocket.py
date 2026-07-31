"""`WS /ws/{ticker}` — canal en vivo alternativo a FCM para que la app/frontend reciba la
alerta apenas se despacha, sin depender de un push nativo del sistema operativo. El
`TickerConnectionManager` compartido vive en `app.state` (armado en el lifespan de
`app/main.py`) para que este endpoint y `PushNotificationService` usen la misma instancia.
"""

from __future__ import annotations

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from app.services.push_service import TickerConnectionManager

router = APIRouter(tags=["websocket"])


@router.websocket("/ws/{ticker}")
async def subscribe_ticker(websocket: WebSocket, ticker: str) -> None:
    connection_manager: TickerConnectionManager = websocket.app.state.connection_manager

    await websocket.accept()
    connection_manager.subscribe(ticker, websocket)
    try:
        while True:
            # No procesamos mensajes entrantes — el cliente solo escucha. `receive_text()` es
            # lo que mantiene la corrutina viva hasta que el cliente cierra la conexión.
            await websocket.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        connection_manager.unsubscribe(ticker, websocket)
