"""Utilidad única de reintentos con backoff exponencial para todos los clientes HTTP del
proyecto — tanto los de `ingestion/` (Polygon, FMP, Tavily, Gemini) como los de
`notification/` (Telegram, Discord). Vive en `core/` porque ambas capas la necesitan y
`notification/` tiene prohibido importar de `ingestion/` directamente (.cursorrules §3); una
utilidad de infraestructura sin lógica de negocio no pertenece a ninguna de las dos, sino a la
base común. Traduce timeouts, errores de transporte y códigos 429/5xx a las excepciones de
dominio de `core/exceptions.py` (.cursorrules §4: "nunca reintentos ad-hoc copiados y pegados
por cliente") — ningún cliente concreto atrapa `httpx.HTTPError` directamente.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

import httpx

from src.core.exceptions import (
    ProviderAuthenticationError,
    ProviderRateLimitError,
    ProviderResponseError,
    ProviderTimeoutError,
)

logger = logging.getLogger(__name__)

_RETRYABLE_STATUS_CODES = frozenset({429, 500, 502, 503, 504})


async def request_with_retries(
    client: httpx.AsyncClient,
    method: str,
    url: str,
    *,
    provider: str,
    max_attempts: int = 3,
    backoff_base_seconds: float = 1.0,
    **kwargs: Any,
) -> httpx.Response:
    """Devuelve la respuesta HTTP cruda para que cada cliente decida cómo parsearla.

    Solo 401/403/429/5xx y errores de transporte/timeout se consideran fallas de proveedor;
    cualquier otro status (incluido 404) se devuelve tal cual para que el llamador decida si
    significa "ticker no encontrado" u otra semántica propia del endpoint.
    """

    last_exc: Exception | None = None

    for attempt in range(1, max_attempts + 1):
        try:
            response = await client.request(method, url, **kwargs)
        except httpx.TimeoutException as exc:
            last_exc = exc
            logger.warning(
                "provider_timeout",
                extra={"provider": provider, "url": url, "attempt": attempt},
            )
        except httpx.TransportError as exc:
            last_exc = exc
            logger.warning(
                "provider_transport_error",
                extra={"provider": provider, "url": url, "attempt": attempt},
            )
        else:
            if response.status_code in (401, 403):
                raise ProviderAuthenticationError(
                    f"{provider}: autenticación o cuota rechazada "
                    f"(status={response.status_code}) en {url}"
                )
            if response.status_code == 429:
                last_exc = ProviderRateLimitError(
                    f"{provider}: rate limit (429) en {url}"
                )
                logger.warning(
                    "provider_rate_limited",
                    extra={"provider": provider, "url": url, "attempt": attempt},
                )
            elif response.status_code in _RETRYABLE_STATUS_CODES:
                last_exc = ProviderResponseError(
                    f"{provider}: status={response.status_code} en {url}"
                )
                logger.warning(
                    "provider_retryable_status",
                    extra={
                        "provider": provider,
                        "status": response.status_code,
                        "url": url,
                        "attempt": attempt,
                    },
                )
            else:
                return response

        if attempt < max_attempts:
            await asyncio.sleep(backoff_base_seconds * (2 ** (attempt - 1)))

    assert last_exc is not None

    if isinstance(last_exc, (ProviderRateLimitError, ProviderResponseError)):
        raise last_exc
    if isinstance(last_exc, httpx.TimeoutException):
        raise ProviderTimeoutError(
            f"{provider}: timeout tras {max_attempts} intentos en {url}"
        ) from last_exc
    raise ProviderResponseError(
        f"{provider}: error de transporte tras {max_attempts} intentos en {url}"
    ) from last_exc
