"""`POST /internal/trigger-agent` — protegido por API key (no JWT de usuario), para que el
Cron/Scheduler dispare el pipeline de LangGraph sobre los tickers activos en las Watchlists.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends

from app.api.deps import AgentRunner
from app.api.deps import verify_internal_api_key as _verify_internal_api_key
from app.schemas.alert import TriggerAgentRequest, TriggerAgentResponse

router = APIRouter(
    prefix="/internal",
    tags=["internal"],
    dependencies=[Depends(_verify_internal_api_key)],
)


@router.post("/trigger-agent", response_model=TriggerAgentResponse)
async def trigger_agent(
    payload: TriggerAgentRequest, agent_runner: AgentRunner
) -> TriggerAgentResponse:
    results = await agent_runner.run_for_tickers(payload.tickers)
    return TriggerAgentResponse(
        tickers_processed=len(results),
        alerts_generated=sum(1 for result in results if result.alert_generated),
        results=results,
    )
