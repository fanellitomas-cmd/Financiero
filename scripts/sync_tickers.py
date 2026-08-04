"""Sincroniza el catálogo local de tickers (`tickers`) desde el endpoint reference de Polygon.

Corre como comando puntual o desde un cron — el catálogo cambia poco (altas, bajas, cambios de
nombre), así que una vez por día es más que suficiente; no tiene sentido meterlo en el
scheduler de alertas, que corre cada 15 minutos.

Uso:
    # Sincronización completa (todas las acciones activas del mercado US)
    python -m scripts.sync_tickers

    # Solo ver qué haría, sin escribir en la DB
    python -m scripts.sync_tickers --dry-run

    # Páginas más chicas (útil para probar contra un plan con rate limit bajo)
    python -m scripts.sync_tickers --page-size 100

Requiere `POLYGON_API_KEY` en `.env`. Al terminar imprime cuántos símbolos se procesaron y el
desglose por bolsa, para poder verificar que el mapeo MIC -> bolsa dio lo esperado (si todo
cae en OTHER, el proveedor cambió el formato de `primary_exchange` — ver la nota de
verificación en `src/ingestion/polygon_client.py`).
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys

from sqlalchemy import func, select

from app.core.database import async_session_factory, create_all_tables
from app.models.ticker import Ticker
from app.services.ticker_catalog_service import (
    TickerCatalogService,
    normalize_exchange,
)
from src.core.config import settings as agent_settings
from src.ingestion.polygon_client import PolygonClient

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s %(message)s")
logger = logging.getLogger("sync_tickers")


async def _print_breakdown() -> None:
    async with async_session_factory() as session:
        rows = (
            await session.execute(
                select(Ticker.exchange, func.count())
                .group_by(Ticker.exchange)
                .order_by(func.count().desc())
            )
        ).all()
    print("\nCatálogo por bolsa:")
    for exchange, count in rows:
        print(f"  {exchange.value:<8} {count}")


async def _dry_run(polygon: PolygonClient, page_size: int) -> None:
    """Trae solo la primera página y muestra cómo quedaría normalizada, sin tocar la DB — la
    forma más rápida de confirmar el contrato del proveedor antes de una corrida completa.
    """

    async for page in polygon.list_stock_tickers(page_size=page_size):
        print(f"Primera página: {len(page)} símbolos. Muestra de 10:\n")
        print(f"  {'SÍMBOLO':<10} {'MIC':<8} {'BOLSA':<8} {'TIPO':<6} NOMBRE")
        for entry in page[:10]:
            print(
                f"  {entry.symbol:<10} {entry.primary_exchange or '—':<8} "
                f"{normalize_exchange(entry.primary_exchange).value:<8} "
                f"{entry.asset_type or '—':<6} {entry.name[:40]}"
            )
        break  # solo la primera página: es un dry-run, no una corrida completa
    print("\n(dry-run: no se escribió nada en la base de datos)")


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--page-size",
        type=int,
        default=1000,
        help="Símbolos por página (default: 1000)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Trae la primera página y la muestra normalizada, sin escribir en la DB",
    )
    args = parser.parse_args()

    if agent_settings.polygon_api_key is None:
        print(
            "ERROR: falta POLYGON_API_KEY en .env — sin credencial no se puede sincronizar.",
            file=sys.stderr,
        )
        return 1

    polygon = PolygonClient(
        agent_settings.polygon_api_key.get_secret_value(),
        base_url=agent_settings.polygon_base_url,
    )

    try:
        if args.dry_run:
            await _dry_run(polygon, args.page_size)
            return 0

        await create_all_tables()
        catalog = TickerCatalogService(async_session_factory)
        total = await catalog.sync_from_polygon(polygon, page_size=args.page_size)
        print(f"\nListo: {total} símbolos procesados.")
        await _print_breakdown()
        return 0
    finally:
        await polygon.aclose()


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
