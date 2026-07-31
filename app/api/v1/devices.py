"""`GET/POST/DELETE /devices` — el usuario autenticado registra los FCM tokens de sus
dispositivos (móvil/web) para poder recibir push personalizado directo, además del
broadcast por tópico/WebSocket que ya cubre `PushNotificationService`.
"""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, HTTPException, status
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.models.device_token import DeviceToken
from app.schemas.device_token import DeviceTokenCreate, DeviceTokenRead

router = APIRouter(prefix="/devices", tags=["devices"])


@router.get("", response_model=list[DeviceTokenRead])
async def list_device_tokens(
    current_user: CurrentUser, session: DbSession
) -> list[DeviceToken]:
    rows = await session.execute(
        select(DeviceToken).where(DeviceToken.user_id == current_user.id)
    )
    return list(rows.scalars().all())


@router.post("", response_model=DeviceTokenRead, status_code=status.HTTP_201_CREATED)
async def register_device_token(
    payload: DeviceTokenCreate, current_user: CurrentUser, session: DbSession
) -> DeviceToken:
    existing = await session.scalar(
        select(DeviceToken).where(DeviceToken.fcm_token == payload.fcm_token)
    )
    if existing is not None:
        # Mismo token físico, posiblemente reinstalado en otra cuenta: se reasigna al
        # usuario actual en vez de fallar, porque el token identifica al dispositivo, no
        # a un usuario en particular.
        existing.user_id = current_user.id
        existing.platform = payload.platform
        await session.commit()
        await session.refresh(existing)
        return existing

    device_token = DeviceToken(
        user_id=current_user.id, fcm_token=payload.fcm_token, platform=payload.platform
    )
    session.add(device_token)
    await session.commit()
    await session.refresh(device_token)
    return device_token


@router.delete("/{device_token_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_device_token(
    device_token_id: UUID, current_user: CurrentUser, session: DbSession
) -> None:
    device_token = await session.scalar(
        select(DeviceToken).where(
            DeviceToken.id == device_token_id, DeviceToken.user_id == current_user.id
        )
    )
    if device_token is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Device token no encontrado."
        )

    await session.delete(device_token)
    await session.commit()
