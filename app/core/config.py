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

    scheduler_enabled: bool = True
    scheduler_interval_minutes: int = 15
    scheduler_market_hours_only: bool = False

    asset_intelligence_max_age_minutes: int = 15
    alert_history_default_page_size: int = 20

    # Clientes web (el cliente Flutter corriendo en modo web, cualquier frontend futuro) llegan
    # desde otro origen (puerto distinto al de la API) — sin CORS habilitado, el navegador
    # bloquea el preflight OPTIONS antes de que la request real salga (405 Method Not Allowed,
    # nunca llega a la ruta). "*" es el default de desarrollo; restringir a dominios concretos
    # en producción.
    cors_allowed_origins: list[str] = ["*"]


app_settings = AppSettings()
