"""Catálogo local de tickers: sincronización desde Polygon y consultas para
`GET /api/v1/tickers`.

Es la capa que INTERPRETA lo que la ingesta solo parseó: traduce el código MIC crudo de
Polygon (`primary_exchange`) a la bolsa del producto (`ExchangeType`). Esa frontera es
deliberada — `src/ingestion/` nunca decide qué significa un valor del proveedor
(.cursorrules §3).
"""

from __future__ import annotations

import logging

from sqlalchemy import func, or_, select, update
from sqlalchemy.dialects.postgresql import insert as postgres_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.enums import ExchangeType
from app.models.ticker import Ticker
from src.ingestion.polygon_client import PolygonClient
from src.ingestion.schemas_raw import ReferenceTicker

logger = logging.getLogger(__name__)

# Códigos MIC (ISO 10383) que Polygon devuelve en `primary_exchange`, mapeados a la bolsa que
# el producto ofrece. Solo se listan los que el usuario puede elegir hoy; el resto cae en
# `OTHER` (ver el docstring de `ExchangeType`).
#
# Los MIC de NYSE American (`XASE`), NYSE Arca (`ARCX`) y Cboe (`BATS`/`XCBO`) NO se mapean a
# `NYSE` a propósito: son bolsas distintas aunque compartan el dueño, y un usuario que elige
# "NYSE" espera el listado del NYSE, no sus afiliadas.
_MIC_TO_EXCHANGE: dict[str, ExchangeType] = {
    "XNAS": ExchangeType.NASDAQ,
    "XNYS": ExchangeType.NYSE,
}


def normalize_exchange(primary_exchange: str | None) -> ExchangeType:
    """MIC crudo de Polygon -> bolsa del producto. Todo lo desconocido (incluido `None`) cae en
    `OTHER`: el ticker se guarda igual y queda visible/auditable, en vez de descartarse o de
    adivinarle una bolsa.
    """

    if primary_exchange is None:
        return ExchangeType.OTHER
    return _MIC_TO_EXCHANGE.get(primary_exchange.upper(), ExchangeType.OTHER)


class TickerCatalogService:
    def __init__(self, session_factory: async_sessionmaker[AsyncSession]) -> None:
        self._session_factory = session_factory

    async def sync_from_polygon(
        self, polygon_client: PolygonClient, *, page_size: int = 1000
    ) -> int:
        """Sincroniza el catálogo completo de acciones. Devuelve la cantidad de símbolos
        procesados (insertados + actualizados).

        Commitea por página en vez de al final: con ~10k símbolos, una transacción única sería
        larga y perdería todo el trabajo ante un fallo a mitad de camino.
        """

        total = 0
        async for page in polygon_client.list_stock_tickers(page_size=page_size):
            await self._upsert_page(page)
            total += len(page)
            logger.info("ticker_catalog_page_synced", extra={"processed": total})
        return total

    async def _upsert_page(self, page: list[ReferenceTicker]) -> None:
        rows = [
            {
                "symbol": entry.symbol.upper(),
                "name": entry.name,
                "primary_exchange": entry.primary_exchange,
                "exchange": normalize_exchange(entry.primary_exchange),
                "asset_type": entry.asset_type,
                "active": entry.active,
                "updated_at": func.now(),
            }
            for entry in page
        ]
        if not rows:
            return

        async with self._session_factory() as session:
            # UPSERT nativo en vez de leer-y-decidir: la sincronización corre periódicamente
            # sobre símbolos que en su mayoría ya existen, y un SELECT por símbolo sería 10k
            # roundtrips. `index_elements=["symbol"]` usa la PK natural de la tabla.
            #
            # `on_conflict_do_update` no existe en el `insert()` genérico de SQLAlchemy, hay
            # que usar el del dialecto — y el proyecto corre SQLite en desarrollo/tests y
            # PostgreSQL en producción, así que se elige en runtime. La API de ambos es
            # idéntica para este caso; hardcodear uno rompería silenciosamente en el otro.
            dialect = session.bind.dialect.name if session.bind is not None else ""
            insert_for_dialect = (
                postgres_insert if dialect == "postgresql" else sqlite_insert
            )
            statement = insert_for_dialect(Ticker).values(rows)
            await session.execute(
                statement.on_conflict_do_update(
                    index_elements=["symbol"],
                    # `sector` NO está en el `set_` a propósito: Polygon no lo devuelve, y
                    # actualizarlo acá lo pisaría con NULL en cada sincronización, tirando el
                    # trabajo que ya hizo la auditoría al resolverlo contra FMP.
                    set_={
                        "name": statement.excluded.name,
                        "primary_exchange": statement.excluded.primary_exchange,
                        "exchange": statement.excluded.exchange,
                        "asset_type": statement.excluded.asset_type,
                        "active": statement.excluded.active,
                        "updated_at": func.now(),
                    },
                )
            )
            await session.commit()

    async def search(
        self,
        *,
        exchange: ExchangeType | None = None,
        query: str | None = None,
        limit: int,
        offset: int,
        active_only: bool = True,
    ) -> tuple[list[Ticker], int]:
        """Devuelve `(página, total)`. El total es el de la consulta completa (sin
        limit/offset) para que el cliente pueda paginar sabiendo cuántos hay.
        """

        filters = []
        if exchange is not None:
            filters.append(Ticker.exchange == exchange)
        if active_only:
            filters.append(Ticker.active.is_(True))
        if query:
            # `ilike` para que la búsqueda no dependa de mayúsculas ni de que el usuario sepa
            # si escribe el símbolo o el nombre de la empresa.
            pattern = f"%{query}%"
            filters.append(
                or_(Ticker.symbol.ilike(pattern), Ticker.name.ilike(pattern))
            )

        async with self._session_factory() as session:
            total = await session.scalar(
                select(func.count()).select_from(Ticker).where(*filters)
            )
            rows = await session.scalars(
                select(Ticker)
                .where(*filters)
                .order_by(Ticker.symbol)
                .limit(limit)
                .offset(offset)
            )
            return list(rows.all()), total or 0

    async def find_name(self, symbol: str) -> str | None:
        """Nombre de la empresa según el catálogo, o `None` si el símbolo no está.

        Lo usa la Ficha de Inteligencia Profunda para titularla con el nombre además del símbolo.
        `None` no es un error: el catálogo cubre acciones de NASDAQ/NYSE, así que una cripto o un
        listado reciente caen acá y la Ficha se muestra igual, solo sin el nombre.
        """

        async with self._session_factory() as session:
            found = await session.scalar(
                select(Ticker.name).where(Ticker.symbol == symbol.upper())
            )
        return found if isinstance(found, str) else None

    async def find_sectors(self, symbols: list[str]) -> dict[str, str]:
        """Sectores (crudos, vocabulario del proveedor) de los símbolos que el catálogo ya conoce.

        Una sola consulta para toda la lista, no una por símbolo: la Auditoría de Portafolio la
        llama con la watchlist entera. Los símbolos sin sector guardado simplemente no aparecen en
        el dict devuelto — el llamador decide si vale la pena resolverlos contra el proveedor.
        """

        normalized = [symbol.upper() for symbol in symbols]
        if not normalized:
            return {}

        async with self._session_factory() as session:
            rows = (
                await session.execute(
                    select(Ticker.symbol, Ticker.sector).where(
                        Ticker.symbol.in_(normalized), Ticker.sector.is_not(None)
                    )
                )
            ).all()

        return {symbol: sector for symbol, sector in rows if isinstance(sector, str)}

    async def store_sectors(self, sectors: dict[str, str]) -> int:
        """Guarda los sectores resueltos contra el proveedor de fundamentales, para los símbolos
        que ya están en el catálogo. Devuelve cuántas filas se actualizaron.

        Es un write-through de caché: el sector de un símbolo es igual para todos los usuarios y no
        cambia de mes a mes, así que resolverlo una vez y persistirlo evita una llamada a FMP por
        símbolo en cada auditoría.

        Deliberadamente NO inserta símbolos ausentes. El catálogo lo puebla la sincronización con
        Polygon, que es la que sabe nombre, bolsa y estado; crear acá una fila con solo símbolo y
        sector metería un registro incompleto que el resto de la app leería como un ticker real
        (aparecería en `GET /tickers` sin nombre ni bolsa). Una cripto o un símbolo no sincronizado
        se queda sin persistir y se resuelve de nuevo la próxima vez — el costo de un `/profile`
        contra un dato inventado en el catálogo.
        """

        if not sectors:
            return 0

        normalized = {symbol.upper(): sector for symbol, sector in sectors.items()}
        async with self._session_factory() as session:
            # Se consulta primero qué símbolos existen en vez de mirar el `rowcount` de cada
            # UPDATE: el conteo devuelto por el driver es la cantidad de filas que la base tocó, que
            # no distingue "el símbolo no está en el catálogo" de "ya tenía ese mismo sector".
            existing = set(
                (
                    await session.scalars(
                        select(Ticker.symbol).where(Ticker.symbol.in_(normalized))
                    )
                ).all()
            )
            for symbol in existing:
                await session.execute(
                    update(Ticker)
                    .where(Ticker.symbol == symbol)
                    .values(sector=normalized[symbol])
                )
            await session.commit()
        return len(existing)

    async def find_exchange(self, symbol: str) -> ExchangeType | None:
        """Bolsa de un símbolo según el catálogo, o `None` si no está. Lo usa
        `POST /api/v1/watchlist` para enriquecer el item sin pedirle el dato al usuario.
        """

        async with self._session_factory() as session:
            found = await session.scalar(
                select(Ticker.exchange).where(Ticker.symbol == symbol.upper())
            )
        # `isinstance` en vez de devolver directo: además de darle un tipo concreto al valor
        # que sale de la DB, descarta un valor guardado por una versión anterior del enum en
        # vez de propagarlo como si fuera una bolsa válida.
        return found if isinstance(found, ExchangeType) else None
