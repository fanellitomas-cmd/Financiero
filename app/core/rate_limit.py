"""Límite de intentos de login, con dos backends intercambiables.

Existe para frenar la fuerza bruta y el credential stuffing contra `POST /auth/login`. Se cuenta
por dos claves a la vez:

  - **email**: la defensa fiable. Un ataque dirigido a una cuenta concreta prueba muchas contraseñas
    contra el mismo email, y esta clave lo corta sin importar desde cuántas IP venga.
  - **IP**: la defensa best-effort. El credential stuffing prueba UNA contraseña filtrada contra
    MUCHAS cuentas desde la misma IP; esta clave lo nota. Es best-effort porque detrás de un NAT o
    un proxy muchos usuarios comparten IP, y porque el `X-Forwarded-For` es falsificable si la app
    quedara expuesta sin el proxy delante — por eso el umbral por IP es holgado y el que realmente
    protege una cuenta es el de email.

Sólo se cuentan los intentos FALLIDOS, y un login exitoso limpia el contador del email: un usuario
que se equivoca una vez y después entra no arrastra el fallo.

Dos backends con la misma interfaz:

  - `RedisLoginRateLimiter`: para producción a escala. `INCR`+`EXPIRE` es O(1), vive en memoria de
    Redis y se autolimpia por TTL, sin tocar la base primaria — que es justo lo que NO se quiere en
    el camino del login, ya de por sí el blanco del ataque. Es el único que sirve con varias
    instancias de Cloud Run: el estado es compartido.
  - `InMemoryLoginRateLimiter`: para desarrollo y tests. Cuenta por proceso, así que con varias
    instancias cada una limita por su lado — inútil a escala, y por eso en `production` sin Redis el
    arranque lo marca como problema (ver `config.production_problems`).

Falla-abierto: si Redis se cae, se permite el login en vez de negarlo. Un limitador que tira abajo
la autenticación cuando su almacén parpadea es un autogol peor que el ataque que previene; el fallo
se registra para que se note.
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass
from typing import Protocol, runtime_checkable

logger = logging.getLogger(__name__)

# Prefijos de las claves. Namespaced para no chocar con otros usos de la misma instancia de Redis.
_EMAIL_KEY_PREFIX = "login-rl:email:"
_IP_KEY_PREFIX = "login-rl:ip:"


@dataclass(frozen=True)
class RateLimitDecision:
    """El veredicto de `check`: si se permite seguir, y si no, cuántos segundos hasta reintentar."""

    allowed: bool
    retry_after_seconds: int = 0


@runtime_checkable
class LoginRateLimiter(Protocol):
    """Interfaz que consume el endpoint de login. El flujo es: `check` antes de gastar un bcrypt,
    `record_failure` si las credenciales fueron inválidas, `record_success` si entró.

    `runtime_checkable` para que el dep pueda comprobar con `isinstance` que lo que hay en
    `app.state` cumple la forma (chequea presencia de métodos, no firmas — suficiente para el guard).
    """

    async def check(self, email: str, ip: str) -> RateLimitDecision: ...
    async def record_failure(self, email: str, ip: str) -> None: ...
    async def record_success(self, email: str, ip: str) -> None: ...
    async def aclose(self) -> None: ...


@dataclass(frozen=True)
class RateLimitConfig:
    max_email_attempts: int
    max_ip_attempts: int
    window_seconds: int


def _normalize_email(email: str) -> str:
    # Se normaliza igual que para buscar el usuario (case-insensitive, sin espacios), así el atacante
    # no evade el contador alternando mayúsculas en el mismo email.
    return email.strip().lower()


class InMemoryLoginRateLimiter:
    """Backend por proceso. Ventana fija que se refresca en cada fallo: mientras los intentos sigan
    entrando dentro de la ventana, el bloqueo se sostiene; se limpia tras `window_seconds` de calma.

    El reloj es inyectable para que los tests no dependan del tiempo real. `time.monotonic` por
    defecto —mide tiempo transcurrido y no lo afecta un ajuste del reloj del sistema—, igual que
    `TtlCache`.
    """

    # Tope de claves vivas: que un atacante rotando emails/IP no convierta esto en una fuga de
    # memoria. Al llegar al tope se purga lo ya vencido antes de insertar.
    _MAX_ENTRIES = 8192

    def __init__(
        self,
        config: RateLimitConfig,
        *,
        clock: "Clock | None" = None,
    ) -> None:
        self._config = config
        self._clock = clock or time.monotonic
        self._lock = asyncio.Lock()
        # clave -> (conteo, momento del primer fallo de la ventana)
        self._hits: dict[str, tuple[int, float]] = {}

    def _count(self, key: str, now: float) -> int:
        entry = self._hits.get(key)
        if entry is None:
            return 0
        count, started = entry
        if now - started >= self._config.window_seconds:
            return 0  # ventana vencida: cuenta como cero (se reescribe en el próximo fallo)
        return count

    def _retry_after(self, key: str, now: float) -> int:
        entry = self._hits.get(key)
        if entry is None:
            return 0
        _, started = entry
        remaining = self._config.window_seconds - (now - started)
        return max(1, int(remaining)) if remaining > 0 else 0

    async def check(self, email: str, ip: str) -> RateLimitDecision:
        ek = _EMAIL_KEY_PREFIX + _normalize_email(email)
        ik = _IP_KEY_PREFIX + ip
        async with self._lock:
            now = self._clock()
            over_email = self._count(ek, now) >= self._config.max_email_attempts
            over_ip = self._count(ik, now) >= self._config.max_ip_attempts
            if not over_email and not over_ip:
                return RateLimitDecision(allowed=True)
            retry = max(
                self._retry_after(ek, now) if over_email else 0,
                self._retry_after(ik, now) if over_ip else 0,
            )
            return RateLimitDecision(allowed=False, retry_after_seconds=retry)

    def _bump(self, key: str, now: float) -> None:
        count = self._count(key, now)
        started = now if count == 0 else self._hits[key][1]
        self._hits[key] = (count + 1, started)

    def _prune(self, now: float) -> None:
        expired = [
            k
            for k, (_, started) in self._hits.items()
            if now - started >= self._config.window_seconds
        ]
        for k in expired:
            del self._hits[k]

    async def record_failure(self, email: str, ip: str) -> None:
        ek = _EMAIL_KEY_PREFIX + _normalize_email(email)
        ik = _IP_KEY_PREFIX + ip
        async with self._lock:
            now = self._clock()
            if len(self._hits) >= self._MAX_ENTRIES:
                self._prune(now)
            self._bump(ek, now)
            self._bump(ik, now)

    async def record_success(self, email: str, ip: str) -> None:
        ek = _EMAIL_KEY_PREFIX + _normalize_email(email)
        async with self._lock:
            self._hits.pop(ek, None)

    async def aclose(self) -> None:
        return None


@runtime_checkable
class AsyncRedisClient(Protocol):
    """El subconjunto de `redis.asyncio.Redis` que se usa acá. Se declara como Protocol para no
    atar el módulo (ni a mypy) a la librería redis: la fábrica inyecta el cliente real, y los tests
    inyectan un doble en memoria que cumple esta misma forma."""

    async def mget(self, keys: list[str]) -> list[str | None]: ...
    async def incr(self, key: str) -> int: ...
    async def expire(self, key: str, seconds: int) -> bool: ...
    async def ttl(self, key: str) -> int: ...
    async def delete(self, *keys: str) -> int: ...
    async def aclose(self) -> None: ...


class RedisLoginRateLimiter:
    """Backend compartido sobre Redis/Memorystore. Ventana fija que se refresca en cada fallo:
    `INCR` la clave y `EXPIRE` a `window_seconds` en cada fallo. Refrescar el TTL en todos los
    fallos (y no sólo al crear la clave) evita el clásico agujero de dejar una clave sin expiración
    si el proceso muere entre el `INCR` y el `EXPIRE`, y sostiene el bloqueo mientras el ataque siga.

    Falla-abierto: cualquier error de Redis se registra y se trata como "permitido". El almacén
    caído no debe poder negar todos los logins.
    """

    def __init__(self, client: AsyncRedisClient, config: RateLimitConfig) -> None:
        self._client = client
        self._config = config

    @staticmethod
    def _as_int(raw: str | None) -> int:
        if raw is None:
            return 0
        try:
            return int(raw)
        except (TypeError, ValueError):
            return 0

    async def check(self, email: str, ip: str) -> RateLimitDecision:
        ek = _EMAIL_KEY_PREFIX + _normalize_email(email)
        ik = _IP_KEY_PREFIX + ip
        try:
            values = await self._client.mget([ek, ik])
            email_count = self._as_int(values[0]) if len(values) > 0 else 0
            ip_count = self._as_int(values[1]) if len(values) > 1 else 0
            over_email = email_count >= self._config.max_email_attempts
            over_ip = ip_count >= self._config.max_ip_attempts
            if not over_email and not over_ip:
                return RateLimitDecision(allowed=True)
            # Sólo cuando se bloquea (caso raro) se paga un TTL extra para el Retry-After exacto.
            retry = 0
            if over_email:
                retry = max(retry, await self._client.ttl(ek))
            if over_ip:
                retry = max(retry, await self._client.ttl(ik))
            # TTL puede volver -1 (sin expiración) o -2 (no existe); en ese borde caemos a la ventana.
            if retry <= 0:
                retry = self._config.window_seconds
            return RateLimitDecision(allowed=False, retry_after_seconds=retry)
        except Exception:  # noqa: BLE001 — falla-abierto a propósito (ver docstring de la clase)
            logger.warning("login rate limiter: check falló, se permite el intento", exc_info=True)
            return RateLimitDecision(allowed=True)

    async def _bump(self, key: str) -> None:
        await self._client.incr(key)
        await self._client.expire(key, self._config.window_seconds)

    async def record_failure(self, email: str, ip: str) -> None:
        ek = _EMAIL_KEY_PREFIX + _normalize_email(email)
        ik = _IP_KEY_PREFIX + ip
        try:
            await self._bump(ek)
            await self._bump(ik)
        except Exception:  # noqa: BLE001 — no romper el login si el contador no se pudo escribir
            logger.warning("login rate limiter: record_failure falló", exc_info=True)

    async def record_success(self, email: str, ip: str) -> None:
        ek = _EMAIL_KEY_PREFIX + _normalize_email(email)
        try:
            await self._client.delete(ek)
        except Exception:  # noqa: BLE001
            logger.warning("login rate limiter: record_success falló", exc_info=True)

    async def aclose(self) -> None:
        await self._client.aclose()


# Alias para el tipo del reloj inyectable del backend en memoria.
class Clock(Protocol):
    def __call__(self) -> float: ...


def build_login_rate_limiter(
    *,
    redis_url: str | None,
    config: RateLimitConfig,
) -> LoginRateLimiter:
    """Arma el limitador según haya o no `redis_url`. La importación de redis es perezosa: la app
    corre sin la librería instalada mientras no se configure un `REDIS_URL`."""

    if not redis_url:
        logger.info("login rate limiter: sin REDIS_URL, usando backend en memoria (por proceso)")
        return InMemoryLoginRateLimiter(config)

    from redis.asyncio import Redis  # import perezoso

    client = Redis.from_url(redis_url, decode_responses=True)
    logger.info("login rate limiter: usando backend Redis")
    return RedisLoginRateLimiter(client, config)
