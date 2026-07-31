"""Cliente de ingesta para Tavily: búsqueda de noticias/contexto web reciente, ya limpio de
ruido HTML, para alimentar el RAG del Nodo 2 (Spec.md §3.2).
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from types import TracebackType
from typing import Any, Self

import httpx

from src.core.exceptions import (
    ProviderAuthenticationError,
    ProviderRateLimitError,
    ProviderResponseError,
    ProviderTimeoutError,
)
from src.ingestion.http_utils import request_with_retries
from src.ingestion.schemas_raw import NewsSearchResult
from src.validation.domain_models import DataStatus, EvidenceItem

logger = logging.getLogger(__name__)

_PROVIDER_NAME = "tavily"
_MAX_EXCERPT_CHARS = 1000


def _parse_published_at(raw: Any) -> datetime | None:
    if not isinstance(raw, str) or not raw:
        return None
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


class TavilyClient:
    def __init__(
        self,
        api_key: str,
        *,
        base_url: str = "https://api.tavily.com",
        timeout_seconds: float = 15.0,
        max_retry_attempts: int = 3,
        http_client: httpx.AsyncClient | None = None,
    ) -> None:
        self._api_key = api_key
        self._max_retry_attempts = max_retry_attempts
        self._owns_client = http_client is None
        self._client = http_client or httpx.AsyncClient(
            base_url=base_url, timeout=httpx.Timeout(timeout_seconds)
        )

    async def aclose(self) -> None:
        if self._owns_client:
            await self._client.aclose()

    async def __aenter__(self) -> Self:
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        await self.aclose()

    async def search_news(
        self,
        query: str,
        *,
        max_results: int = 5,
        days: int | None = None,
        search_depth: str = "advanced",
    ) -> NewsSearchResult:
        """Busca noticias recientes para `query`. Un fallo del proveedor devuelve
        `articles=[]` con `status != OK` — nunca artículos inventados ni un resultado vacío
        indistinguible de "no hay noticias" (.cursorrules §1).
        """

        fetched_at = datetime.now(timezone.utc)
        body: dict[str, Any] = {
            "api_key": self._api_key,
            "query": query,
            "search_depth": search_depth,
            "topic": "news",
            "max_results": max_results,
            "include_answer": False,
            "include_raw_content": False,
        }
        if days is not None:
            body["days"] = days

        try:
            response = await request_with_retries(
                self._client,
                "POST",
                "/search",
                provider=_PROVIDER_NAME,
                max_attempts=self._max_retry_attempts,
                json=body,
            )
        except (
            ProviderTimeoutError,
            ProviderRateLimitError,
            ProviderAuthenticationError,
            ProviderResponseError,
        ) as exc:
            logger.warning(
                "tavily_search_failed", extra={"query": query, "error": str(exc)}
            )
            return NewsSearchResult(
                query=query,
                fetched_at=fetched_at,
                status=DataStatus.ERROR_API,
                articles=[],
            )

        try:
            payload = response.json()
        except ValueError:
            return NewsSearchResult(
                query=query,
                fetched_at=fetched_at,
                status=DataStatus.ERROR_API,
                articles=[],
            )

        results = payload.get("results") if isinstance(payload, dict) else None
        if not isinstance(results, list):
            return NewsSearchResult(
                query=query,
                fetched_at=fetched_at,
                status=DataStatus.ERROR_API,
                articles=[],
            )

        articles: list[EvidenceItem] = []
        for index, entry in enumerate(results):
            if not isinstance(entry, dict):
                continue
            content = entry.get("content")
            if not isinstance(content, str):
                continue
            articles.append(
                EvidenceItem(
                    ref_id=f"tavily:{fetched_at.isoformat()}:{index}",
                    source_type="NEWS",
                    url=entry.get("url") if isinstance(entry.get("url"), str) else None,
                    published_at=_parse_published_at(entry.get("published_date")),
                    excerpt=content[:_MAX_EXCERPT_CHARS],
                )
            )

        return NewsSearchResult(
            query=query, fetched_at=fetched_at, status=DataStatus.OK, articles=articles
        )
