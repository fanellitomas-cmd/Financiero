"""Adaptadores que implementan los puertos de `core/dependencies.py` (`MarketDataProvider`,
`DeepResearchProvider`) usando los clientes concretos de ingesta. Los nodos de `processing/`
dependen solo del Protocol — nunca importan `PolygonClient`/`FMPClient`/`TavilyClient`
directamente (.cursorrules §3). Componer estos adaptadores es responsabilidad del composition
root (`src/composition.py`), no de los nodos.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone
from decimal import Decimal
from typing import Literal
from uuid import uuid4

from src.ingestion.fmp_client import FMPClient
from src.ingestion.polygon_client import PolygonClient
from src.ingestion.schemas_raw import FilingReference, MarketSnapshot, NewsSearchResult
from src.ingestion.tavily_client import TavilyClient
from src.validation.domain_models import (
    AlertSeverity,
    AlertTriggerType,
    AssetClass,
    DataStatus,
    EvidenceItem,
    FinancialMetrics,
    MarketAlert,
    MetricValue,
    ResearchDossier,
    WatchedAsset,
)

logger = logging.getLogger(__name__)


class PolygonMarketDataAdapter:
    """Implementa `MarketDataProvider` (Nodo 1, Spec.md §3.1): pide un snapshot a Polygon y
    evalúa un umbral de variación diaria para decidir severidad.

    `WatchedAsset` todavía no incorpora `AlertThresholds` por-usuario (Spec.md §2.1) — hasta
    que lo haga, este adaptador aplica un umbral único configurable en el constructor en vez
    de fabricar una configuración por usuario que no existe.
    """

    def __init__(
        self,
        polygon_client: PolygonClient,
        *,
        medium_threshold_pct: Decimal = Decimal("3.0"),
        high_threshold_pct: Decimal = Decimal("6.0"),
        critical_threshold_pct: Decimal = Decimal("10.0"),
    ) -> None:
        self._polygon = polygon_client
        self._medium = medium_threshold_pct
        self._high = high_threshold_pct
        self._critical = critical_threshold_pct

    async def fetch_snapshot_and_detect_alert(
        self, asset: WatchedAsset
    ) -> MarketAlert | None:
        snapshot = (
            await self._polygon.get_crypto_snapshot(asset.ticker)
            if asset.asset_class == AssetClass.CRYPTO
            else await self._polygon.get_equity_snapshot(asset.ticker)
        )
        return self._detect_alert(asset, snapshot)

    def _detect_alert(
        self, asset: WatchedAsset, snapshot: MarketSnapshot
    ) -> MarketAlert | None:
        change = snapshot.day_change_pct
        if change.status != DataStatus.OK or change.value is None:
            logger.info(
                "market_data_unavailable",
                extra={"ticker": asset.ticker, "status": change.status.value},
            )
            return None

        severity = self._severity_for(abs(change.value))
        if severity is None:
            return None

        return MarketAlert(
            alert_id=str(uuid4()),
            ticker=asset.ticker,
            asset_class=asset.asset_class,
            trigger_type=AlertTriggerType.PRICE_MOVE,
            severity=severity,
            detected_at=snapshot.fetched_at,
            trigger_value=change.value,
            threshold_breached=self._medium,
            requires_deep_research=severity != AlertSeverity.LOW,
            raw_context_snapshot={
                "last_price": _metric_repr(snapshot.last_price),
                "volume": _metric_repr(snapshot.volume),
                "day_change_pct": _metric_repr(change),
            },
        )

    def _severity_for(self, magnitude: Decimal) -> AlertSeverity | None:
        if magnitude >= self._critical:
            return AlertSeverity.CRITICAL
        if magnitude >= self._high:
            return AlertSeverity.HIGH
        if magnitude >= self._medium:
            return AlertSeverity.MEDIUM
        return None


def _metric_repr(metric: MetricValue) -> str:
    """Representación legible de un `MetricValue` para logs/contexto crudo — nunca "None"
    silencioso: si el valor falta, muestra explícitamente el status (NO_DISPONIBLE/ERROR_API).
    """

    if metric.value is not None:
        return str(metric.value)
    return metric.status.value


class FundamentalsAndNewsResearchAdapter:
    """Implementa `DeepResearchProvider` (Nodo 2, Spec.md §3.2) combinando noticias (Tavily),
    filings SEC (FMP) y fundamentales/ratios (FMP) — el contexto financiero verificado que
    consume el Nodo 3 (Spec.md §3.3) junto con la síntesis cualitativa.

    No sintetiza con un LLM todavía: `summary` es una concatenación factual de lo
    efectivamente recuperado, nunca una interpretación. La síntesis con Gemini (ver
    `prompts/analyst_system_prompt.md`) consumirá este dossier como su `<research_dossier>`
    en un paso posterior — implementarla aquí sería adelantar el Nodo 3, no el Nodo 2.
    """

    def __init__(
        self,
        tavily_client: TavilyClient,
        fmp_client: FMPClient,
        *,
        max_news_results: int = 5,
        news_lookback_days: int = 7,
    ) -> None:
        self._tavily = tavily_client
        self._fmp = fmp_client
        self._max_news_results = max_news_results
        self._news_lookback_days = news_lookback_days

    async def build_dossier(
        self, asset: WatchedAsset, alert: MarketAlert
    ) -> ResearchDossier:
        query = f"{asset.ticker} {alert.trigger_type.value.replace('_', ' ').lower()}"

        filings_10k: list[FilingReference] = []
        filings_10q: list[FilingReference] = []
        financial_metrics: FinancialMetrics | None = None

        if asset.asset_class == AssetClass.EQUITY:
            (
                news_result,
                filings_10k,
                filings_10q,
                financial_metrics,
            ) = await asyncio.gather(
                self._tavily.search_news(
                    query,
                    max_results=self._max_news_results,
                    days=self._news_lookback_days,
                ),
                self._fmp.list_recent_filings(asset.ticker, "10-K", limit=1),
                self._fmp.list_recent_filings(asset.ticker, "10-Q", limit=1),
                self._fmp.get_financial_metrics(asset.ticker),
            )
        else:
            news_result = await self._tavily.search_news(
                query, max_results=self._max_news_results, days=self._news_lookback_days
            )

        evidence: list[EvidenceItem] = list(news_result.articles)
        evidence.extend(
            _filing_to_evidence(filing) for filing in (*filings_10k, *filings_10q)
        )

        return ResearchDossier(
            ticker=asset.ticker,
            generated_at=datetime.now(timezone.utc),
            summary=_build_factual_summary(
                asset, alert, news_result, filings_10k, filings_10q, financial_metrics
            ),
            evidence=evidence,
            financial_metrics=financial_metrics,
        )


def _filing_to_evidence(filing: FilingReference) -> EvidenceItem:
    filed_label = (
        filing.filed_at.date().isoformat() if filing.filed_at else "fecha no disponible"
    )
    source_type: Literal["SEC_10K", "SEC_10Q"] = (
        "SEC_10K" if filing.filing_type == "10-K" else "SEC_10Q"
    )
    return EvidenceItem(
        ref_id=f"fmp:{filing.filing_type}:{filing.ticker}:{filed_label}",
        source_type=source_type,
        url=filing.final_document_url or filing.filing_url,
        published_at=filing.filed_at,
        excerpt=f"Filing {filing.filing_type} de {filing.ticker} presentado el {filed_label}.",
    )


def _build_factual_summary(
    asset: WatchedAsset,
    alert: MarketAlert,
    news_result: NewsSearchResult,
    filings_10k: list[FilingReference],
    filings_10q: list[FilingReference],
    financial_metrics: FinancialMetrics | None,
) -> str:
    lines = [
        (
            f"Alerta {alert.severity.value} ({alert.trigger_type.value}) detectada para "
            f"{asset.ticker} con variación de {alert.trigger_value}%."
        )
    ]

    if news_result.status == DataStatus.OK:
        lines.append(
            f"Se encontraron {len(news_result.articles)} artículos de noticias recientes."
        )
    else:
        lines.append(
            f"La búsqueda de noticias falló (status={news_result.status.value}); "
            "sin cobertura de prensa para esta alerta."
        )

    if asset.asset_class == AssetClass.EQUITY:
        if filings_10k or filings_10q:
            lines.append(
                f"Filings recuperados: {len(filings_10k)} 10-K, {len(filings_10q)} 10-Q."
            )
        else:
            lines.append("No se encontraron filings 10-K/10-Q recientes.")

        if financial_metrics is not None:
            available = sum(
                1
                for field_name in _FUNDAMENTAL_METRIC_FIELDS
                if getattr(financial_metrics, field_name).status == DataStatus.OK
            )
            lines.append(
                f"Fundamentales FMP: {available}/{len(_FUNDAMENTAL_METRIC_FIELDS)} "
                "métricas disponibles."
            )
        else:
            lines.append(
                "No se pudieron recuperar fundamentales de FMP para esta alerta."
            )

    return " ".join(lines)


_FUNDAMENTAL_METRIC_FIELDS = (
    "price_earnings_ratio",
    "price_earnings_growth_ratio",
    "debt_to_ebitda",
    "free_cash_flow",
    "free_cash_flow_yield_pct",
    "revenue_growth_yoy_pct",
    "gross_margin_pct",
    "operating_margin_pct",
    "return_on_equity_pct",
    "current_ratio",
    "shares_outstanding",
    "market_cap",
)
