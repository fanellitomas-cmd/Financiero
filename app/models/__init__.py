"""Importar este paquete registra todos los modelos ORM en `Base.metadata` — necesario para
que `create_all_tables()` (`app/core/database.py`) sepa qué tablas crear.
"""

from app.models.alert_history import AlertHistory
from app.models.device_token import DeviceToken
from app.models.ticker import Ticker
from app.models.user import User
from app.models.watchlist import WatchlistItem

__all__ = ["AlertHistory", "DeviceToken", "Ticker", "User", "WatchlistItem"]
