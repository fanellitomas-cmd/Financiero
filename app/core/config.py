"""Configuración de la API/backend (capa de Producto y Plataforma) — separada de
`src/core/config.py::Settings`, que configura el motor de LangGraph. Esta capa nunca importa
credenciales del motor directamente; las usa a través de `src.core.config.settings` donde
haga falta (ver `app/services/agent_runner_service.py`).
"""

from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


DEFAULT_SECRET_PLACEHOLDER = "change-me-in-production"


class AppSettings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # `production` activa las verificaciones de `assert_production_ready()`. No cambia ninguna otra
    # conducta: la diferencia entre entornos es qué se exige, no qué se hace.
    environment: str = "development"

    database_url: str = "sqlite+aiosqlite:///./financiero.db"
    database_echo: bool = False

    jwt_secret_key: SecretStr = SecretStr(DEFAULT_SECRET_PLACEHOLDER)
    jwt_algorithm: str = "HS256"
    jwt_access_token_expire_minutes: int = 60 * 24

    internal_api_key: SecretStr = SecretStr(DEFAULT_SECRET_PLACEHOLDER)

    # Código que hay que presentar para crear una cuenta. `None` deja el registro ABIERTO, que es lo
    # que corresponde en desarrollo y lo que NO corresponde en una URL pública: sin código, cualquiera
    # que encuentre el link se crea usuario y gasta las llamadas a los proveedores.
    #
    # Es un secreto compartido, no un sistema de invitaciones: no lleva registro de quién lo usó ni
    # expira. Alcanza para "solo entra quien yo invité"; no alcanza para revocarle el acceso a una
    # persona sin rotarlo para todas.
    registration_invite_code: SecretStr | None = None

    # Almacén compartido del límite de intentos de login (Redis/Memorystore). `None` cae al backend
    # en memoria, que cuenta por proceso: con varias instancias de Cloud Run cada una limitaría por su
    # lado y un atacante obtendría N veces el límite. Por eso en `production` sin esto el arranque lo
    # marca como problema — salvo que se acepte explícitamente el modo en memoria (ver el flag de abajo).
    redis_url: SecretStr | None = None

    # Escotilla para el lanzamiento a costo cero: con `True`, `production` NO exige `REDIS_URL` y usa
    # el limitador en memoria. Es seguro SÓLO con una única instancia (`--max-instances=1` en Cloud
    # Run): ahí el conteo por proceso es el conteo global. Con más de una instancia el límite se
    # afloja y hay que pasar a Redis. Default `False`: la config lista para escalar es la segura.
    login_rate_limit_allow_in_memory: bool = False

    # Umbrales del límite de intentos de login, por ventana. El de email es el que protege una cuenta
    # concreta (fuerza bruta dirigida) y es ajustado; el de IP es holgado porque detrás de un NAT
    # muchos usuarios legítimos comparten IP. Sólo se cuentan los intentos fallidos.
    login_rate_limit_max_email_attempts: int = 5
    login_rate_limit_max_ip_attempts: int = 50
    login_rate_limit_window_seconds: int = 900

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

    @property
    def is_production(self) -> bool:
        return self.environment.strip().lower() == "production"

    def production_problems(self) -> list[str]:
        """Qué falta para poder publicar esto, en una lista legible.

        Se devuelve la lista COMPLETA en vez de fallar en el primer problema: quien está desplegando
        quiere arreglar todo de una, no descubrir el siguiente error en el próximo intento.
        """

        problems: list[str] = []

        if self.jwt_secret_key.get_secret_value() == DEFAULT_SECRET_PLACEHOLDER:
            problems.append(
                "JWT_SECRET_KEY sigue en el placeholder del repo: cualquiera que lea el código "
                "podría firmar un token válido para cualquier cuenta. Generá uno con "
                '`python -c "import secrets; print(secrets.token_urlsafe(48))"`.'
            )
        if self.internal_api_key.get_secret_value() == DEFAULT_SECRET_PLACEHOLDER:
            problems.append(
                "INTERNAL_API_KEY sigue en el placeholder del repo: protege los endpoints internos "
                "del scheduler y con el default queda abierta."
            )
        if "*" in self.cors_allowed_origins:
            problems.append(
                "CORS_ALLOWED_ORIGINS acepta cualquier origen: un sitio ajeno podría llamar a la "
                "API desde el navegador de un usuario logueado. Poné el dominio del frontend."
            )
        if self.database_url.startswith("sqlite"):
            problems.append(
                "DATABASE_URL apunta a SQLite. En Cloud Run el disco es efímero, así que cada "
                "reinicio borraría usuarios y notas. Usá la URL de Cloud SQL (postgresql+asyncpg)."
            )
        if self.redis_url is None and not self.login_rate_limit_allow_in_memory:
            problems.append(
                "REDIS_URL no está configurado: el límite de intentos de login caería al backend en "
                "memoria, que cuenta por proceso. Con Cloud Run escalando a varias instancias eso deja "
                "el login casi sin protección contra fuerza bruta (cada instancia limita por su lado). "
                "Para lanzar a costo cero, corré una sola instancia (--max-instances=1) y poné "
                "LOGIN_RATE_LIMIT_ALLOW_IN_MEMORY=true para aceptarlo explícitamente. Al escalar, "
                "usá Memorystore (Redis) — ver DEPLOY.md."
            )
        return problems

    def assert_production_ready(self) -> None:
        """Frena el arranque si el entorno dice `production` y algo quedó en su default de desarrollo.

        Es un fallo al ARRANCAR y no un warning a propósito: un warning en los logs de un despliegue
        automático no lo lee nadie, y el costo de equivocarse acá es una base de datos abierta.
        """

        if not self.is_production:
            return
        problems = self.production_problems()
        if problems:
            listed = "\n  - ".join(problems)
            raise RuntimeError(
                f"ENVIRONMENT=production pero la configuración no está lista:\n  - {listed}"
            )


app_settings = AppSettings()
