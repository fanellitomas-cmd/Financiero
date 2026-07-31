"""Tests de `AgentScheduler`/`is_market_hours`: el job periódico llama a
`AgentRunnerService.run_for_tickers(None)`, se salta la corrida fuera de horario de mercado
cuando corresponde, y un fallo al resolver la watchlist se degrada sin propagar.
"""

from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from app.models.enums import AssetType
from app.schemas.alert import TickerRunResult
from app.services import scheduler as scheduler_module
from app.services.scheduler import AgentScheduler, is_market_hours

_NYSE_TIMEZONE = ZoneInfo("America/New_York")


def test_is_market_hours_true_on_weekday_during_session() -> None:
    tuesday_noon = datetime(2026, 7, 28, 12, 0, tzinfo=_NYSE_TIMEZONE)
    assert is_market_hours(tuesday_noon) is True


def test_is_market_hours_false_on_weekend() -> None:
    saturday_noon = datetime(2026, 8, 1, 12, 0, tzinfo=_NYSE_TIMEZONE)
    assert is_market_hours(saturday_noon) is False


def test_is_market_hours_false_outside_session_hours() -> None:
    tuesday_night = datetime(2026, 7, 28, 22, 0, tzinfo=_NYSE_TIMEZONE)
    assert is_market_hours(tuesday_night) is False


class _FakeAgentRunnerService:
    def __init__(self, results: list[TickerRunResult] | None = None) -> None:
        self.results = results or []
        self.calls: list[list[str] | None] = []
        self.should_raise = False

    async def run_for_tickers(self, tickers: list[str] | None) -> list[TickerRunResult]:
        self.calls.append(tickers)
        if self.should_raise:
            raise RuntimeError("db caida")
        return self.results


async def test_run_job_calls_run_for_tickers_with_all_watchlist_tickers() -> None:
    fake_service = _FakeAgentRunnerService(
        results=[
            TickerRunResult(
                ticker="NVDA", asset_type=AssetType.STOCK, alert_generated=True
            )
        ]
    )
    agent_scheduler = AgentScheduler(
        fake_service,
        interval_minutes=15,
        market_hours_only=False,
    )

    await agent_scheduler._run_job()
    # el AsyncIOScheduler real ni esperar un intervalo.

    assert fake_service.calls == [None]


async def test_run_job_skips_outside_market_hours(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(scheduler_module, "is_market_hours", lambda: False)
    fake_service = _FakeAgentRunnerService()
    agent_scheduler = AgentScheduler(
        fake_service,
        interval_minutes=15,
        market_hours_only=True,
    )

    await agent_scheduler._run_job()

    assert fake_service.calls == []


async def test_run_job_degrades_when_run_for_tickers_raises() -> None:
    fake_service = _FakeAgentRunnerService()
    fake_service.should_raise = True
    agent_scheduler = AgentScheduler(
        fake_service,
        interval_minutes=15,
        market_hours_only=False,
    )

    await agent_scheduler._run_job()


async def test_scheduler_starts_and_shuts_down_cleanly() -> None:
    fake_service = _FakeAgentRunnerService()
    agent_scheduler = AgentScheduler(
        fake_service,
        interval_minutes=15,
        market_hours_only=False,
    )

    agent_scheduler.start()
    agent_scheduler.shutdown()
