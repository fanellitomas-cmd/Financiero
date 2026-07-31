"""`GET /api/v1/assets/{ticker}` — Ficha de Inteligencia Profunda on-demand (Pantalla 3): lee
el último análisis persistido si es reciente, o corre el motor sincrónicamente para este único
ticker si no. Requiere `asset_type` como query param porque el ticker puede no estar todavía
en ninguna Watchlist (a diferencia del cron, que solo conoce tickers ya seguidos).
"""

from __future__ import annotations

import logging
from datetime import timedelta

from fastapi import APIRouter, HTTPException, status

from app.api.deps import AgentRunner, CurrentUser
from app.core.config import app_settings
from app.models.enums import AssetType
from app.services.agent_runner_service import AssetIntelligenceUnavailableError
from src.validation.domain_models import PushNotificationPayload

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/assets", tags=["assets"])


@router.get("/{ticker}", response_model=PushNotificationPayload)
async def get_asset_intelligence(
    ticker: str,
    asset_type: AssetType,
    current_user: CurrentUser,
    agent_runner: AgentRunner,
) -> PushNotificationPayload:
    try:
        return await agent_runner.get_or_compute_payload(
            ticker,
            asset_type,
            max_age=timedelta(minutes=app_settings.asset_intelligence_max_age_minutes),
        )
    except AssetIntelligenceUnavailableError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=str(exc),
        ) from exc
    except Exception as exc:
        # Fallo genuino en runtime (proveedor caído, timeout, bug) no debe devolver un 500
        # opaco: se registra explícito y se traduce a un 502 con mensaje claro para el
        # cliente (.cursorrules §2: degradar explícito). No hace falta `noqa: BLE001` acá —
        # ese lint es sobre except que TRAGAN la excepción; esta la re-lanza (`from exc`).
        logger.error(
            "asset_intelligence_on_demand_failed",
            extra={"ticker": ticker, "error": str(exc)},
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="No se pudo generar el análisis del activo en este momento.",
        ) from exc
