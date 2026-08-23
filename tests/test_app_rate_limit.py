"""Tests del límite de intentos de login: los dos backends por unidad, y el 429 de punta a punta.

El backend Redis se prueba contra un doble en memoria que cumple el Protocol `AsyncRedisClient`, así
no hace falta un Redis real en CI. El backend en memoria usa un reloj inyectado para no depender del
tiempo de pared.
"""

from __future__ import annotations

import httpx

from app.core.rate_limit import (
    AsyncRedisClient,
    InMemoryLoginRateLimiter,
    RateLimitConfig,
    RedisLoginRateLimiter,
    build_login_rate_limiter,
)


class _FakeClock:
    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t

    def advance(self, seconds: float) -> None:
        self.t += seconds


class _FakeRedis:
    """Doble en memoria de las operaciones de Redis que usa el limitador. TTL simplificado: guarda el
    vencimiento absoluto contra un reloj inyectado."""

    def __init__(self, clock: _FakeClock) -> None:
        self._clock = clock
        self._values: dict[str, int] = {}
        self._expires_at: dict[str, float] = {}
        self.fail_next = False  # para simular una caída de Redis

    def _maybe_fail(self) -> None:
        if self.fail_next:
            self.fail_next = False
            raise RuntimeError("redis caído")

    def _sweep(self) -> None:
        now = self._clock()
        for k in [k for k, exp in self._expires_at.items() if exp <= now]:
            self._values.pop(k, None)
            self._expires_at.pop(k, None)

    async def mget(self, keys: list[str]) -> list[str | None]:
        self._maybe_fail()
        self._sweep()
        return [str(self._values[k]) if k in self._values else None for k in keys]

    async def incr(self, key: str) -> int:
        self._maybe_fail()
        self._sweep()
        self._values[key] = self._values.get(key, 0) + 1
        return self._values[key]

    async def expire(self, key: str, seconds: int) -> bool:
        self._maybe_fail()
        if key in self._values:
            self._expires_at[key] = self._clock() + seconds
            return True
        return False

    async def ttl(self, key: str) -> int:
        self._maybe_fail()
        self._sweep()
        if key not in self._values:
            return -2
        if key not in self._expires_at:
            return -1
        return max(0, int(self._expires_at[key] - self._clock()))

    async def delete(self, *keys: str) -> int:
        self._maybe_fail()
        n = 0
        for k in keys:
            if self._values.pop(k, None) is not None:
                n += 1
            self._expires_at.pop(k, None)
        return n

    async def aclose(self) -> None:
        return None


def _config() -> RateLimitConfig:
    return RateLimitConfig(max_email_attempts=3, max_ip_attempts=5, window_seconds=60)


# --------------------------------------------------------------------------- backend en memoria


async def test_inmemory_blocks_after_email_limit() -> None:
    clock = _FakeClock()
    limiter = InMemoryLoginRateLimiter(_config(), clock=clock)

    for _ in range(3):
        assert (await limiter.check("a@x.com", "1.1.1.1")).allowed
        await limiter.record_failure("a@x.com", "1.1.1.1")

    decision = await limiter.check("a@x.com", "1.1.1.1")
    assert not decision.allowed
    assert decision.retry_after_seconds > 0


async def test_inmemory_window_expires() -> None:
    clock = _FakeClock()
    limiter = InMemoryLoginRateLimiter(_config(), clock=clock)

    for _ in range(3):
        await limiter.record_failure("a@x.com", "1.1.1.1")
    assert not (await limiter.check("a@x.com", "1.1.1.1")).allowed

    clock.advance(61)  # pasada la ventana, el contador cuenta como cero
    assert (await limiter.check("a@x.com", "1.1.1.1")).allowed


async def test_inmemory_success_resets_email_counter() -> None:
    clock = _FakeClock()
    limiter = InMemoryLoginRateLimiter(_config(), clock=clock)

    for _ in range(2):
        await limiter.record_failure("a@x.com", "1.1.1.1")
    await limiter.record_success("a@x.com", "1.1.1.1")
    # tras entrar, el contador del email vuelve a cero: dos fallos más no deberían bloquear todavía
    for _ in range(2):
        assert (await limiter.check("a@x.com", "1.1.1.1")).allowed
        await limiter.record_failure("a@x.com", "1.1.1.1")


async def test_inmemory_email_case_insensitive() -> None:
    clock = _FakeClock()
    limiter = InMemoryLoginRateLimiter(_config(), clock=clock)
    for _ in range(3):
        await limiter.record_failure("A@X.com", "1.1.1.1")
    # el mismo email en otra capitalización comparte contador
    assert not (await limiter.check("a@x.com", "1.1.1.1")).allowed


async def test_inmemory_ip_limit_independent_of_email() -> None:
    clock = _FakeClock()
    limiter = InMemoryLoginRateLimiter(_config(), clock=clock)
    # 5 fallos desde la misma IP contra emails distintos (credential stuffing): dispara el límite por IP
    for i in range(5):
        await limiter.record_failure(f"user{i}@x.com", "9.9.9.9")
    decision = await limiter.check("otro@x.com", "9.9.9.9")
    assert not decision.allowed


# --------------------------------------------------------------------------- backend Redis (doble)


async def test_redis_blocks_after_email_limit() -> None:
    clock = _FakeClock()
    fake = _FakeRedis(clock)
    limiter = RedisLoginRateLimiter(fake, _config())

    for _ in range(3):
        assert (await limiter.check("a@x.com", "1.1.1.1")).allowed
        await limiter.record_failure("a@x.com", "1.1.1.1")

    decision = await limiter.check("a@x.com", "1.1.1.1")
    assert not decision.allowed
    assert decision.retry_after_seconds > 0


async def test_redis_ttl_expires_window() -> None:
    clock = _FakeClock()
    fake = _FakeRedis(clock)
    limiter = RedisLoginRateLimiter(fake, _config())

    for _ in range(3):
        await limiter.record_failure("a@x.com", "1.1.1.1")
    assert not (await limiter.check("a@x.com", "1.1.1.1")).allowed

    clock.advance(61)
    assert (await limiter.check("a@x.com", "1.1.1.1")).allowed


async def test_redis_success_resets_email() -> None:
    clock = _FakeClock()
    fake = _FakeRedis(clock)
    limiter = RedisLoginRateLimiter(fake, _config())

    for _ in range(2):
        await limiter.record_failure("a@x.com", "1.1.1.1")
    await limiter.record_success("a@x.com", "1.1.1.1")
    for _ in range(2):
        assert (await limiter.check("a@x.com", "1.1.1.1")).allowed
        await limiter.record_failure("a@x.com", "1.1.1.1")


async def test_redis_fails_open_on_error() -> None:
    """Si Redis se cae en el `check`, se permite el intento (falla-abierto): un almacén caído no debe
    poder negar todos los logins."""

    clock = _FakeClock()
    fake = _FakeRedis(clock)
    limiter = RedisLoginRateLimiter(fake, _config())

    fake.fail_next = True
    decision = await limiter.check("a@x.com", "1.1.1.1")
    assert decision.allowed


def test_redis_double_satisfies_protocol() -> None:
    assert isinstance(_FakeRedis(_FakeClock()), AsyncRedisClient)


def test_factory_uses_inmemory_without_url() -> None:
    limiter = build_login_rate_limiter(redis_url=None, config=_config())
    assert isinstance(limiter, InMemoryLoginRateLimiter)


# --------------------------------------------------------------------------- integración de punta a punta


async def test_login_returns_429_after_repeated_failures(client: httpx.AsyncClient) -> None:
    """Tras superar el umbral de intentos fallidos, el login responde 429 con `Retry-After`, y no
    401. El conftest arma un limitador en memoria fresco por test con los umbrales por defecto
    (5 por email)."""

    await client.post(
        "/api/v1/auth/register",
        json={"email": "brute@example.com", "password": "supersecreta1"},
    )

    saw_429 = False
    for _ in range(8):
        resp = await client.post(
            "/api/v1/auth/login",
            json={"email": "brute@example.com", "password": "incorrecta"},
        )
        if resp.status_code == 429:
            saw_429 = True
            assert resp.headers.get("Retry-After") is not None
            assert int(resp.headers["Retry-After"]) > 0
            break
        assert resp.status_code == 401

    assert saw_429, "el login nunca aplicó el límite de intentos"


async def test_login_success_before_limit_still_works(client: httpx.AsyncClient) -> None:
    """Unos pocos fallos por debajo del umbral no impiden entrar con la contraseña correcta, y el
    éxito limpia el contador."""

    await client.post(
        "/api/v1/auth/register",
        json={"email": "ok@example.com", "password": "supersecreta1"},
    )
    for _ in range(3):
        bad = await client.post(
            "/api/v1/auth/login",
            json={"email": "ok@example.com", "password": "incorrecta"},
        )
        assert bad.status_code == 401

    good = await client.post(
        "/api/v1/auth/login",
        json={"email": "ok@example.com", "password": "supersecreta1"},
    )
    assert good.status_code == 200
    assert "access_token" in good.json()
