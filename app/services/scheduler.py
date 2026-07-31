"""Scheduler en segundo plano que dispara periódicamente el pipeline de LangGraph sobre los
tickers activos en las Watchlists — el "Cron" de producción, corriendo dentro del propio
proceso de la API (`app/main.py::lifespan`).

Usamos APScheduler (`AsyncIOScheduler`) en vez de Celery/RQ: un único job periódico
in-process no necesita un broker separado (Redis/RabbitMQ) ni workers distribuidos — eso
sería infraestructura extra sin necesidad clara para este caso (.cursorrules §1: preferir
la solución más simple que resuelve el problema real). APScheduler corre nativamente en el
mismo event loop de uvicorn.

Llama a `AgentRunnerService.run_for_tickers(None)` DIRECTO in-process, nunca por HTTP contra
el propio `POST /api/v1/internal/trigger-agent`: el scheduler y el servicio viven en el mismo
proceso, así que un round-trip HTTP hacia sí mismo sería puro overhead (misma razón por la
que el Nodo 5 del grafo no despacha directo — ver el comentario en `app/main.py`).
"""

from __future__ import annotations

import logging
from datetime import datetime
from datetime import time as dt_time
from typing import Protocol
from zoneinfo import ZoneInfo

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.interval import IntervalTrigger

from app.schemas.alert import TickerRunResult

logger = logging.getLogger(__name__)


class AgentRunnerLike(Protocol):
    """Lo mínimo que `AgentScheduler` necesita de `AgentRunnerService` — un `Protocol`
    estructural en vez de importar la clase concreta, para poder testear el job con un doble
    de prueba sin `type: ignore` (mismo patrón que `BroadcastTarget` en
    `app/services/push_service.py`); un `AgentRunnerService` real lo satisface tal cual.
    """

    async def run_for_tickers(
        self, tickers: list[str] | None
    ) -> list[TickerRunResult]: ...


_NYSE_TIMEZONE = ZoneInfo("America/New_York")
_MARKET_OPEN = dt_time(9, 30)
_MARKET_CLOSE = dt_time(16, 0)
_JOB_ID = "trigger_agent_active_watchlists"


def is_market_hours(now: datetime | None = None) -> bool:
    """Aproximación simple del horario regular del NYSE (Lu-Vi 9:30-16:00 hora de Nueva York,
    sin considerar feriados bursátiles). Suficiente para no correr el pipeline de noche/fin de
    semana cuando `scheduler_market_hours_only=True`; un calendario de feriados exacto queda
    fuera de alcance de este esqueleto.
    """

    moment = (now or datetime.now(_NYSE_TIMEZONE)).astimezone(_NYSE_TIMEZONE)
    if moment.weekday() >= 5:  # sábado=5, domingo=6
        return False
    return _MARKET_OPEN <= moment.time() <= _MARKET_CLOSE


class AgentScheduler:
    """Envuelve un `AsyncIOScheduler` con un único job recurrente. `start()`/`shutdown()` se
    llaman desde el lifespan de la app — nunca se instancia más de una vez por proceso.
    """

    def __init__(
        self,
        agent_runner_service: AgentRunnerLike,
        *,
        interval_minutes: int,
        market_hours_only: bool,
    ) -> None:
        self._agent_runner_service = agent_runner_service
        self._market_hours_only = market_hours_only
        self._scheduler = AsyncIOScheduler(timezone="UTC")
        self._scheduler.add_job(
            self._run_job,
            trigger=IntervalTrigger(minutes=interval_minutes),
            id=_JOB_ID,
            max_instances=1,
            coalesce=True,
        )

    def start(self) -> None:
        self._scheduler.start()
        logger.info(
            "agent_scheduler_started",
            extra={"market_hours_only": self._market_hours_only},
        )

    def shutdown(self) -> None:
        self._scheduler.shutdown(wait=False)
        logger.info("agent_scheduler_stopped")

    async def _run_job(self) -> None:
        if self._market_hours_only and not is_market_hours():
            logger.info("agent_scheduler_skip_outside_market_hours")
            return

        try:
            results = await self._agent_runner_service.run_for_tickers(None)
        except Exception as exc:  # noqa: BLE001 — un fallo al resolver la watchlist (ej. DB
            # caída) no debe tumbar el scheduler ni las corridas futuras: se degrada y se
            # registra explícitamente (.cursorrules §2), y el próximo intervalo reintenta solo.
            logger.error("agent_scheduler_run_failed", extra={"error": str(exc)})
            return

        logger.info(
            "agent_scheduler_run_completed",
            extra={
                "tickers_processed": len(results),
                "alerts_generated": sum(
                    1 for result in results if result.alert_generated
                ),
            },
        )
