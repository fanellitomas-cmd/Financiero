from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    max_guardrail_retries: int = 2
    min_data_completeness_pct_high_confidence: float = 80.0
    min_data_completeness_pct_medium_confidence: float = 60.0
    request_timeout_seconds: float = 15.0


settings = Settings()
