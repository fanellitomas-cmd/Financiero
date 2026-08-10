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
    ticker_default_page_size: int = 50

    # El resumen de mercado es el mismo para todos los usuarios, así que se cachea en memoria:
    # sin esto, cada apertura del Dashboard sería una llamada a Gemini. 15 minutos es del orden
    # del intervalo del scheduler — el resumen no cambia de sentido en menos que eso.
    market_summary_cache_ttl_seconds: float = 900.0
    market_summary_movers_per_direction: int = 5

    # La Ficha de Inteligencia Profunda es la operación más cara del sistema (una llamada al LLM
    # más cuatro a proveedores por ticker), y su contenido —fundamentales trimestrales, síntesis de
    # reportes, tesis a 1-3 años— no cambia de sentido en una hora.
    ticker_intelligence_cache_ttl_seconds: float = 3600.0

    # La auditoría cruza la watchlist entera contra dos proveedores (sector por símbolo nuevo,
    # histórico diario por símbolo) más una llamada al modelo. Su resultado depende de la
    # composición de la cartera, que cambia cuando el usuario agrega o quita un ticker — y eso ya
    # invalida la caché por sí solo (la clave incluye la huella de la watchlist), así que el TTL
    # solo cubre el envejecimiento de los precios.
    portfolio_audit_cache_ttl_seconds: float = 3600.0
    # 90 días de rueda son ~60 observaciones: suficiente para que una correlación signifique algo y
    # corto como para que refleje el régimen actual del mercado y no el de hace dos años.
    portfolio_audit_correlation_window_days: int = 90
    # 0.8 es alto a propósito. El objetivo es marcar activos que se mueven casi como uno solo, no
    # constatar que dos acciones del mismo índice se parecen: con un umbral de 0.5 medio S&P 500
    # aparecería advertido y la señal dejaría de significar nada.
    portfolio_audit_correlation_threshold: float = 0.8
    # Debajo de esto no se afirma una correlación: con pocos días en común el coeficiente es ruido
    # con forma de número.
    portfolio_audit_min_observations: int = 30
    # Tope de símbolos a los que se les pide histórico en una auditoría, para que una watchlist
    # enorme no convierta un endpoint de lectura en una tormenta de tráfico contra el proveedor.
    portfolio_audit_max_history_tickers: int = 25

    # Cuántas filas del catálogo puede traer la búsqueda en lenguaje natural después de filtrar por
    # sector/bolsa/texto. Sin tope, "tecnológicas" traería miles de filas a memoria para descartar
    # casi todas.
    search_nl_max_candidates: int = 60
    # A cuántos de esos candidatos se les piden los ratios. Es el número caro: `get_financial_metrics`
    # pega a CINCO endpoints de FMP por símbolo, así que 12 son ~60 requests dentro de un request
    # HTTP. Los candidatos que quedan afuera no entran en los resultados cuando la consulta tiene
    # filtros numéricos — no se puede afirmar que cumplen algo que no se les midió.
    search_nl_max_metric_lookups: int = 12

    # Las traducciones se cachean por contenido y no cambian nunca (el mismo texto da la misma
    # explicación), así que el TTL es largo: 24 horas.
    financial_translator_cache_ttl_seconds: float = 86400.0
    financial_translator_max_cache_entries: int = 500

    # Corporate Hub. Un TTL por vista y no uno global: un calendario de balances cambia de hora en
    # hora (llegan los reportados del día), un histórico de trimestres cerrados no cambia en meses, y
    # un feed de noticias envejece en minutos. Un TTL único obligaría a elegir entre gastar llamadas
    # de más en lo estable o servir noticias viejas.
    corporate_calendar_cache_ttl_seconds: float = 3600.0
    corporate_history_cache_ttl_seconds: float = 21600.0
    corporate_filings_cache_ttl_seconds: float = 3600.0
    corporate_news_cache_ttl_seconds: float = 900.0
    corporate_max_news_results: int = 20
    corporate_max_filings: int = 20

    # Laboratorio Financiero. Los estados contables tienen el TTL más largo de toda la app (6 h) por
    # una razón simple: un balance publicado no cambia hasta el próximo reporte, así que volver a
    # pedirlo gasta cuota sin poder traer nada nuevo. La capitalización sí se mueve con el precio
    # durante la rueda, y por eso tiene su propio TTL corto.
    ai_lab_statements_cache_ttl_seconds: float = 21600.0
    ai_lab_metrics_cache_ttl_seconds: float = 3600.0

    # Cuántos períodos contables se piden. Cinco alcanzan para ver una tendencia; más filas engordan
    # el prompt sin cambiar el diagnóstico.
    ai_lab_statement_periods: int = 5

    # Clientes web (el cliente Flutter corriendo en modo web, cualquier frontend futuro) llegan
    # desde otro origen (puerto distinto al de la API) — sin CORS habilitado, el navegador
    # bloquea el preflight OPTIONS antes de que la request real salga (405 Method Not Allowed,
    # nunca llega a la ruta). "*" es el default de desarrollo; restringir a dominios concretos
    # en producción.
    cors_allowed_origins: list[str] = ["*"]


app_settings = AppSettings()
