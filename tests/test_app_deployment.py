"""Tests de lo que hace falta para publicar: código de invitación y verificaciones de producción.

Son tests de configuración, no de negocio, y existen por el mismo motivo que el guard de arranque:
el costo de equivocarse acá no es una pantalla mal dibujada, es una base de datos abierta.
"""

from __future__ import annotations

import httpx
import pytest
from pydantic import SecretStr

from app.core.config import DEFAULT_SECRET_PLACEHOLDER, AppSettings, app_settings


@pytest.fixture
def invite_code() -> object:
    """Configura un código de invitación y lo desarma al terminar.

    Se toca el singleton `app_settings` porque es lo que lee el endpoint. El `finally` no es opcional:
    sin él, el código quedaría puesto para los otros ~660 tests y el registro empezaría a devolver 403
    en todos.
    """

    previous = app_settings.registration_invite_code
    app_settings.registration_invite_code = SecretStr("pase-secreto")
    try:
        yield
    finally:
        app_settings.registration_invite_code = previous


class TestInviteCode:
    async def test_sin_codigo_configurado_el_registro_queda_abierto(
        self, client: httpx.AsyncClient
    ) -> None:
        """Es el comportamiento de desarrollo: sin `REGISTRATION_INVITE_CODE`, alta libre."""

        response = await client.post(
            "/api/v1/auth/register",
            json={"email": "abierto@example.com", "password": "supersecreta1"},
        )
        assert response.status_code == 201

    async def test_con_codigo_configurado_un_alta_sin_codigo_es_403(
        self, client: httpx.AsyncClient, invite_code: object
    ) -> None:
        response = await client.post(
            "/api/v1/auth/register",
            json={"email": "sincodigo@example.com", "password": "supersecreta1"},
        )

        assert response.status_code == 403
        assert "código de invitación" in response.json()["detail"]

    async def test_un_codigo_equivocado_es_403(
        self, client: httpx.AsyncClient, invite_code: object
    ) -> None:
        response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": "malcodigo@example.com",
                "password": "supersecreta1",
                "invite_code": "no-es-este",
            },
        )
        assert response.status_code == 403

    async def test_el_codigo_correcto_crea_la_cuenta(
        self, client: httpx.AsyncClient, invite_code: object
    ) -> None:
        response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": "invitado@example.com",
                "password": "supersecreta1",
                "invite_code": "pase-secreto",
            },
        )

        assert response.status_code == 201
        assert response.json()["email"] == "invitado@example.com"

    async def test_los_espacios_alrededor_del_codigo_no_lo_invalidan(
        self, client: httpx.AsyncClient, invite_code: object
    ) -> None:
        """Un código pegado desde un chat se trae espacios; rechazarlo por eso sería una trampa."""

        response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": "pegado@example.com",
                "password": "supersecreta1",
                "invite_code": "  pase-secreto  ",
            },
        )
        assert response.status_code == 201

    async def test_el_codigo_se_verifica_antes_de_mirar_la_base(
        self, client: httpx.AsyncClient, invite_code: object
    ) -> None:
        """Sin este orden, el 409 de "email ya existe" permitiría enumerar cuentas sin el código."""

        await client.post(
            "/api/v1/auth/register",
            json={
                "email": "existente@example.com",
                "password": "supersecreta1",
                "invite_code": "pase-secreto",
            },
        )

        repeat = await client.post(
            "/api/v1/auth/register",
            json={"email": "existente@example.com", "password": "supersecreta1"},
        )

        # 403 y no 409: quien no tiene el código no aprende nada sobre qué emails están tomados.
        assert repeat.status_code == 403

    async def test_el_login_no_pide_codigo(
        self, client: httpx.AsyncClient, invite_code: object
    ) -> None:
        """El código controla las ALTAS, no el acceso: pedirlo en cada login obligaría a guardarlo."""

        await client.post(
            "/api/v1/auth/register",
            json={
                "email": "vuelve@example.com",
                "password": "supersecreta1",
                "invite_code": "pase-secreto",
            },
        )

        login = await client.post(
            "/api/v1/auth/login",
            json={"email": "vuelve@example.com", "password": "supersecreta1"},
        )
        assert login.status_code == 200


class TestProductionReadiness:
    def test_en_desarrollo_no_se_exige_nada(self) -> None:
        settings = AppSettings(environment="development")
        settings.assert_production_ready()  # no lanza

    def test_el_secreto_del_repo_frena_el_arranque(self) -> None:
        settings = AppSettings(environment="production")

        with pytest.raises(RuntimeError) as failure:
            settings.assert_production_ready()

        assert "JWT_SECRET_KEY" in str(failure.value)

    def test_se_reportan_TODOS_los_problemas_juntos(self) -> None:
        """Quien despliega quiere arreglar todo de una, no descubrir el siguiente en el próximo
        intento.
        """

        problems = AppSettings(environment="production").production_problems()

        joined = " ".join(problems)
        assert "JWT_SECRET_KEY" in joined
        assert "INTERNAL_API_KEY" in joined
        assert "CORS_ALLOWED_ORIGINS" in joined
        assert "DATABASE_URL" in joined

    def test_sqlite_se_señala_porque_cloud_run_borra_el_disco(self) -> None:
        settings = AppSettings(
            environment="production",
            jwt_secret_key=SecretStr("un-secreto-de-verdad"),
            internal_api_key=SecretStr("otro-secreto-de-verdad"),
            cors_allowed_origins=["https://financiero.example"],
        )

        problems = settings.production_problems()
        assert len(problems) == 1
        assert "SQLite" in problems[0]

    def test_una_configuracion_completa_pasa(self) -> None:
        settings = AppSettings(
            environment="production",
            jwt_secret_key=SecretStr("un-secreto-de-verdad"),
            internal_api_key=SecretStr("otro-secreto-de-verdad"),
            cors_allowed_origins=["https://financiero.example"],
            database_url="postgresql+asyncpg://user:pass@/db?host=/cloudsql/x",
        )

        assert settings.production_problems() == []
        settings.assert_production_ready()

    def test_el_placeholder_es_el_mismo_string_que_el_default(self) -> None:
        """Si alguien cambia el default y no la constante, la verificación dejaría de detectarlo."""

        assert (
            AppSettings().jwt_secret_key.get_secret_value()
            == DEFAULT_SECRET_PLACEHOLDER
        )
