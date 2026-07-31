"""Importar este paquete registra todos los modelos ORM en `Base.metadata` — necesario para
que `create_all_tables()` (`app/core/database.py`) sepa qué tablas crear.
"""

from app.models.alert_history import AlertHistory
from app.models.user import User
from app.models.watchlist import WatchlistItem

__all__ = ["AlertHistory", "User", "WatchlistItem"]
