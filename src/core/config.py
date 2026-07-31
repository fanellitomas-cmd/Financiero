from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    max_guardrail_retries: int = 2
    min_data_completeness_pct_high_confidence: float = 80.0
    min_data_completeness_pct_medium_confidence: float = 60.0
    request_timeout_seconds: float = 15.0

    ingestion_max_retry_attempts: int = 3
    ingestion_retry_backoff_base_seconds: float = 1.0

    polygon_api_key: SecretStr | None = None
    polygon_base_url: str = "https://api.polygon.io"

    fmp_api_key: SecretStr | None = None
    fmp_base_url: str = "https://financialmodelingprep.com/stable"

    tavily_api_key: SecretStr | None = None
    tavily_base_url: str = "https://api.tavily.com"

    gemini_api_key: SecretStr | None = None
    gemini_base_url: str = "https://generativelanguage.googleapis.com/v1beta"
    gemini_model: str = "gemini-1.5-pro"
    gemini_temperature: float = 0.2
    gemini_timeout_seconds: float = 30.0

    telegram_bot_token: SecretStr | None = None
    telegram_chat_id: str | None = None
    telegram_base_url: str = "https://api.telegram.org"

    discord_webhook_url: SecretStr | None = None


settings = Settings()
