"""Schemas Pydantic v2 de request/response para `POST /api/v1/chat`."""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field


class ChatRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    prompt: str = Field(min_length=1, max_length=2000)
    ticker: str | None = Field(default=None, min_length=1, max_length=20)


class ChatResponse(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    reply: str
    referenced_ticker: str | None = None
    grounded_in_recent_alert: bool = False
