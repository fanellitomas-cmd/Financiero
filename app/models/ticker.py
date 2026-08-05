"""Tabla `tickers`: catálogo local de acciones sincronizado desde el endpoint reference de
Polygon (`/v3/reference/tickers`). Es la fuente de verdad para saber en qué bolsa cotiza un
símbolo — el dato que hasta ahora no existía en ningún lado del sistema y que hacía imposible
filtrar por NASDAQ/NYSE.
"""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import Boolean, DateTime, String, func
from sqlalchemy import Enum as SAEnum
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base
from app.models.enums import ExchangeType


class Ticker(Base):
    __tablename__ = "tickers"

    # `symbol` como PK en vez de un UUID (a diferencia del resto de las tablas): es la clave
    # natural del catálogo — Polygon garantiza un símbolo único por mercado — y hace que el
    # upsert de la sincronización sea directo, sin un SELECT previo para resolver el id.
    symbol: Mapped[str] = mapped_column(String(20), primary_key=True)

    name: Mapped[str] = mapped_column(String(255), nullable=False)

    # Código MIC crudo tal como lo devuelve Polygon (`XNAS`, `XNYS`, `ARCX`…). Se guarda sin
    # interpretar, además de la forma normalizada en `exchange`: si el mapeo MIC -> ExchangeType
    # resultara incompleto o equivocado, se puede recalcular desde acá sin volver a sincronizar
    # el catálogo entero contra el proveedor. Nullable porque Polygon puede omitirlo.
    primary_exchange: Mapped[str | None] = mapped_column(String(20), nullable=True)

    # Forma normalizada de `primary_exchange` — es la columna que filtra la API (indexada).
    exchange: Mapped[ExchangeType] = mapped_column(
        SAEnum(ExchangeType, native_enum=False, length=16),
        nullable=False,
        index=True,
    )

    # Tipo de instrumento en el vocabulario de Polygon (`CS` = common stock, `ETF`, `ADRC`…),
    # crudo y sin interpretar. NO es el `AssetType` del producto (STOCK/CRYPTO, ver
    # `app/models/enums.py`) — son dos vocabularios distintos y no se mezclan.
    asset_type: Mapped[str | None] = mapped_column(String(16), nullable=True)

    # Sector en el vocabulario del proveedor de fundamentales (`Technology`, `Healthcare`…), tal
    # como lo devuelve FMP `/profile`. Polygon NO trae sector, así que esta columna la completa la
    # Auditoría de Portafolio cuando resuelve un símbolo por primera vez (write-through), no la
    # sincronización del catálogo — y por eso el upsert de `sync_from_polygon` la deja intacta en
    # vez de sobreescribirla con NULL en cada corrida.
    #
    # Se guarda el valor crudo del proveedor, no el `PortfolioSector` normalizado del producto:
    # mismo criterio que `primary_exchange` contra `exchange` — si el mapeo del producto cambia,
    # se recalcula desde acá sin volver a pegarle a FMP por cada símbolo.
    sector: Mapped[str | None] = mapped_column(String(64), nullable=True)

    active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)

    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )
