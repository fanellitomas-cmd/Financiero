"""Caché por TTL compartida por los servicios que consultan proveedores externos.

Vive en `core/` porque ya la usan dos servicios con la misma necesidad exacta —el Hub Corporativo y
el Laboratorio Financiero— y las dos partes difíciles de esto (medir el tiempo con el reloj correcto
y coalescer los requests concurrentes) no deberían tener dos implementaciones que puedan divergir.
"""

from __future__ import annotations

import asyncio
import time
from typing import Any

# Tope de entradas por caché. Existe para que un patrón de claves que nunca se repiten (un ticker
# distinto por consulta) no la convierta en una fuga de memoria.
DEFAULT_MAX_ENTRIES = 128


class TtlCache:
    """Caché por TTL con desalojo por orden de inserción.

    `time.monotonic` y no `datetime.now`: mide tiempo transcurrido, y un ajuste del reloj del sistema
    no debería invalidarla ni eternizarla.

    El `Lock` NO es para proteger el `dict` (el GIL alcanza), sino para que dos requests simultáneos
    por la misma clave no disparen dos veces la llamada al proveedor. Con una pantalla abierta en dos
    pestañas eso es el caso normal, no el raro.
    """

    def __init__(
        self, *, ttl_seconds: float, max_entries: int = DEFAULT_MAX_ENTRIES
    ) -> None:
        self._ttl = ttl_seconds
        self._max_entries = max_entries
        self._entries: dict[str, tuple[float, Any]] = {}
        self._locks: dict[str, asyncio.Lock] = {}

    def get(self, key: str) -> Any | None:
        entry = self._entries.get(key)
        if entry is None:
            return None
        stored_at, value = entry
        if time.monotonic() - stored_at > self._ttl:
            del self._entries[key]
            return None
        return value

    def set(self, key: str, value: Any) -> None:
        if len(self._entries) >= self._max_entries:
            oldest = next(iter(self._entries))
            del self._entries[oldest]
        self._entries[key] = (time.monotonic(), value)

    def lock_for(self, key: str) -> asyncio.Lock:
        lock = self._locks.get(key)
        if lock is None:
            lock = asyncio.Lock()
            self._locks[key] = lock
            # Los locks se podan junto con las entradas para que la tabla no crezca sin límite con
            # claves que nunca se repiten. Un lock TOMADO no se poda aunque su clave no esté
            # cacheada: es el de un request en vuelo, y sacarlo del diccionario dejaría que el
            # siguiente cree otro y llame al proveedor en paralelo, que es exactamente lo que el
            # lock existe para evitar.
            if len(self._locks) > self._max_entries * 2:
                for stale, stale_lock in list(self._locks.items()):
                    if (
                        stale != key
                        and stale not in self._entries
                        and not stale_lock.locked()
                    ):
                        del self._locks[stale]
        return lock

    def clear(self) -> None:
        self._entries.clear()
