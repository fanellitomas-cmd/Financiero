"""Configuración de la API/backend (capa de Producto y Plataforma) — separada de
`src/core/config.py::Settings`, que configura el motor de LangGraph. Esta capa nunca importa
credenciales del motor directamente; las usa a través de `src.core.config.settings` donde
haga falta (ver `app/services/agent_runner_service.py`).
"""

from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class AppSettings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str = "sqlite+aiosqlite:///./financiero.db"
    database_echo: bool = False

    jwt_secret_key: SecretStr = SecretStr("change-me-in-production")
    jwt_algorithm: str = "HS256"
    jwt_access_token_expire_minutes: int = 60 * 24

    internal_api_key: SecretStr = SecretStr("change-me-in-production")

    default_alert_threshold_pct: str = "3.0"


app_settings = AppSettings()
