"""Tests del Corporate Intelligence Hub: `/api/v1/corporate/*`.

Los contratos que este módulo promete y que son fáciles de romper sin darse cuenta:

  1. **Una sorpresa porcentual sobre una base cercana a cero no se calcula.** `(0.05 − (−0.01)) /
     0.01` da 600%, un número que existe y no significa nada. Si el piso desapareciera, la UI
     mostraría sorpresas históricas donde solo hubo redondeo — y nada fallaría.
  2. **La categoría y el sentimiento son heurísticos y lo declaran.** Un titular etiquetado BEARISH
     no es el veredicto de un analista. Si `classification_source` dejara de viajar, el cliente no
     tendría forma de presentarlo con el peso que tiene.
  3. **Lista vacía por falta de credenciales ≠ lista vacía porque no hay datos.** Las dos responden
     200 con `events: []`; lo único que las distingue es `availability` y el motivo.
  4. **La caché no cachea fallos** y sirve la misma llamada a dos filtros distintos: el filtro se
     aplica en código sobre lo cacheado, así que cambiar de pestaña no gasta un request.
  5. **Sin Gemini, los reportes se listan igual.** La síntesis es lo que falta, y por eso su motivo
     va en un campo aparte del general.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from typing import Any

import httpx
import pytest

from app.main import app
from app.schemas.corporate import (
    MIN_ABS_ESTIMATE_FOR_PCT,
    EarningsSession,
    EarningsStatus,
    FilingType,
    NewsCategory,
    NewsSentiment,
    SurpriseDirection,
)
from app.schemas.intelligence import DataAvailability
from app.services.corporate_service import (
    REASON_FMP_FAILED,
    REASON_GEMINI_SUMMARY_FAILED,
    REASON_NO_FMP,
    REASON_NO_GEMINI_SUMMARY,
    REASON_NO_TAVILY,
    REASON_TAVILY_FAILED,
    CorporateService,
    build_earnings_event,
    classify_category,
    classify_direction,
    classify_sentiment,
    compute_surprise,
    extract_source,
    news_ref_id,
    parse_filing_type,
    parse_session,
    summarize_history,
)
from src.ingestion.schemas_raw import (
    FilingReference,
    GeminiGenerationResult,
    NewsSearchResult,
)
from src.validation.domain_models import DataStatus, EvidenceItem

# --- Dobles ------------------------------------------------------------------------------------


class _FakeFMP:
    """Doble del `FMPClient` para las tres vistas que dependen de él."""

    def __init__(
        self,
        *,
        calendar_rows: list[dict[str, Any]] | None = None,
        history_rows: list[dict[str, Any]] | None = None,
        filings: list[FilingReference] | None = None,
        status: DataStatus = DataStatus.OK,
    ) -> None:
        self._calendar_rows = calendar_rows or []
        self._history_rows = history_rows or []
        self._filings = filings or []
        self._status = status

        self.calendar_calls = 0
        self.history_calls = 0
        self.filings_calls = 0

    async def get_earnings_calendar(
        self, from_date: date, to_date: date
    ) -> tuple[list[dict[str, Any]], DataStatus]:
        self.calendar_calls += 1
        if self._status != DataStatus.OK:
            return [], self._status
        return self._calendar_rows, DataStatus.OK

    async def get_earnings_history(
        self, ticker: str, *, limit: int = 8
    ) -> tuple[list[dict[str, Any]], DataStatus]:
        self.history_calls += 1
        if self._status != DataStatus.OK:
            return [], self._status
        return self._history_rows[:limit], DataStatus.OK

    async def list_recent_filings_with_status(
        self, ticker: str, filing_type: str | None = None, *, limit: int = 4
    ) -> tuple[list[FilingReference], DataStatus]:
        self.filings_calls += 1
        if self._status != DataStatus.OK:
            return [], self._status
        return self._filings[:limit], DataStatus.OK


class _FakeTavily:
    def __init__(
        self,
        *,
        articles: list[EvidenceItem] | None = None,
        status: DataStatus = DataStatus.OK,
    ) -> None:
        self._articles = articles or []
        self._status = status
        self.calls = 0

    async def search_news(
        self,
        query: str,
        *,
        max_results: int = 5,
        days: int | None = None,
        search_depth: str = "advanced",
    ) -> NewsSearchResult:
        self.calls += 1
        return NewsSearchResult(
            query=query,
            fetched_at=datetime.now(timezone.utc),
            status=self._status,
            articles=self._articles if self._status == DataStatus.OK else [],
        )


class _FakeGemini:
    def __init__(
        self, *, raw_json_text: str | None, status: DataStatus = DataStatus.OK
    ):
        self._raw = raw_json_text
        self._status = status
        self.calls = 0

    async def generate_structured_json(
        self,
        *,
        system_instruction: str,
        user_content: str,
        response_schema: dict[str, Any],
        temperature: float = 0.2,
        model: str | None = None,
    ) -> GeminiGenerationResult:
        self.calls += 1
        return GeminiGenerationResult(
            status=self._status,
            raw_json_text=self._raw,
            finish_reason="STOP" if self._status is DataStatus.OK else None,
            model="fake-gemini",
            generated_at=datetime(2026, 2, 21, 12, 0, tzinfo=timezone.utc),
        )


def _service(**kwargs: Any) -> CorporateService:
    return CorporateService(system_prompt="Prompt de prueba.", **kwargs)


def _article(
    *,
    title: str,
    excerpt: str = "Cuerpo de la nota.",
    url: str | None = "https://www.reuters.com/markets/nvda-story",
    published_at: datetime | None = None,
) -> EvidenceItem:
    return EvidenceItem(
        ref_id="tavily:1",
        source_type="NEWS",
        url=url,
        published_at=published_at or datetime(2026, 8, 5, 12, tzinfo=timezone.utc),
        excerpt=excerpt,
        title=title,
    )


def _filing(
    filing_type: str = "10-K", filed_at: datetime | None = None
) -> FilingReference:
    return FilingReference(
        ticker="NVDA",
        filing_type=filing_type,
        filed_at=filed_at or datetime(2026, 2, 21, tzinfo=timezone.utc),
        accepted_at=None,
        filing_url="https://sec.example/filing",
        final_document_url="https://sec.example/doc",
    )


async def _auth(client: httpx.AsyncClient, email: str) -> dict[str, str]:
    await client.post(
        "/api/v1/auth/register", json={"email": email, "password": "supersecreta1"}
    )
    login = await client.post(
        "/api/v1/auth/login", json={"email": email, "password": "supersecreta1"}
    )
    return {"Authorization": f"Bearer {login.json()['access_token']}"}


# --- Cálculo de sorpresas ------------------------------------------------------------------------


class TestComputeSurprise:
    def test_calcula_diferencia_y_porcentaje(self) -> None:
        surprise, pct = compute_surprise(
            1.00, 1.20, min_abs_estimate=MIN_ABS_ESTIMATE_FOR_PCT
        )
        assert surprise == pytest.approx(0.20)
        assert pct == pytest.approx(20.0)

    def test_un_estimado_cercano_a_cero_no_produce_porcentaje(self) -> None:
        """El caso que esta función existe para evitar: `(0.05 − (−0.01)) / 0.01` = 600%, un número
        que existe y no significa nada. La empresa no superó las expectativas en 600%; la base era
        ruido.
        """

        surprise, pct = compute_surprise(
            -0.01, 0.05, min_abs_estimate=MIN_ABS_ESTIMATE_FOR_PCT
        )

        # La diferencia absoluta SÍ se informa: "reportó 6 centavos más de lo esperado" es verdad.
        assert surprise == pytest.approx(0.06)
        assert pct is None

    def test_un_estimado_exactamente_cero_tampoco(self) -> None:
        surprise, pct = compute_surprise(
            0.0, 0.30, min_abs_estimate=MIN_ABS_ESTIMATE_FOR_PCT
        )
        assert surprise == pytest.approx(0.30)
        assert pct is None

    def test_el_porcentaje_usa_el_valor_absoluto_del_estimado(self) -> None:
        """Con un estimado NEGATIVO grande, superarlo es una buena noticia y el signo del porcentaje
        tiene que reflejarlo. Dividir por el estimado con signo daría el resultado al revés.
        """

        surprise, pct = compute_surprise(-2.00, -1.00, min_abs_estimate=0.01)

        assert surprise == pytest.approx(1.00)
        assert pct is not None and pct > 0

    def test_sin_alguno_de_los_dos_no_hay_sorpresa(self) -> None:
        assert compute_surprise(None, 1.2, min_abs_estimate=0.01) == (None, None)
        assert compute_surprise(1.2, None, min_abs_estimate=0.01) == (None, None)


class TestClassifyDirection:
    def test_beat_miss_e_in_line(self) -> None:
        assert classify_direction(0.20) is SurpriseDirection.BEAT
        assert classify_direction(-0.20) is SurpriseDirection.MISS
        # Medio centavo es redondeo, no una sorpresa: marcarlo BEAT convertiría ruido en señal.
        assert classify_direction(0.002) is SurpriseDirection.IN_LINE
        assert classify_direction(0.0) is SurpriseDirection.IN_LINE

    def test_sin_sorpresa_medida_es_desconocida(self) -> None:
        assert classify_direction(None) is SurpriseDirection.UNKNOWN


class TestSummarizeHistory:
    def test_el_denominador_son_los_trimestres_medidos(self) -> None:
        """Un trimestre sin estimación no se puede contar ni como acierto ni como fallo. Meterlo en
        el denominador haría parecer menos consistente a la empresa por un hueco del proveedor.
        """

        quarters = [
            build_earnings_event(
                {
                    "symbol": "NVDA",
                    "date": "2026-05-01",
                    "epsEstimated": 1.0,
                    "eps": 1.3,
                }
            ),
            build_earnings_event(
                {
                    "symbol": "NVDA",
                    "date": "2026-02-01",
                    "epsEstimated": 1.0,
                    "eps": 0.7,
                }
            ),
            # Sin estimación: reportó, pero no hay contra qué medirlo.
            build_earnings_event({"symbol": "NVDA", "date": "2025-11-01", "eps": 0.9}),
        ]
        assert all(quarter is not None for quarter in quarters)

        beats, misses, in_line, measured, average = summarize_history(
            [quarter for quarter in quarters if quarter is not None]
        )

        assert (beats, misses, in_line) == (1, 1, 0)
        assert measured == 2
        assert average == pytest.approx(0.0)

    def test_sin_porcentajes_medibles_el_promedio_es_none(self) -> None:
        """Un promedio sobre cero muestras es 0, y 0 significa "reportó exactamente lo esperado" —
        una afirmación distinta de "no se pudo medir".
        """

        quarter = build_earnings_event(
            {"symbol": "X", "date": "2026-05-01", "epsEstimated": 0.0, "eps": 0.4}
        )
        assert quarter is not None

        _, _, _, _, average = summarize_history([quarter])
        assert average is None


# --- Normalización de eventos ---------------------------------------------------------------------


class TestBuildEarningsEvent:
    def test_arma_el_evento_completo_con_sorpresas(self) -> None:
        event = build_earnings_event(
            {
                "symbol": "nvda",
                "name": "NVIDIA Corporation",
                "date": "2026-08-27",
                "time": "amc",
                "period": "Q2 2027",
                "epsEstimated": 1.00,
                "eps": 1.25,
                "revenueEstimated": 45_000_000_000,
                "revenue": 46_100_000_000,
            }
        )

        assert event is not None
        assert event.ticker == "NVDA"
        assert event.company_name == "NVIDIA Corporation"
        assert event.event_date == date(2026, 8, 27)
        assert event.session is EarningsSession.AMC
        assert event.status is EarningsStatus.REPORTED
        assert event.fiscal_period == "Q2 2027"
        assert event.eps_surprise == pytest.approx(0.25)
        assert event.eps_surprise_pct == pytest.approx(25.0)
        assert event.revenue_surprise_pct == pytest.approx(2.444, abs=0.01)
        assert event.surprise_direction is SurpriseDirection.BEAT

    def test_el_cierre_del_trimestre_viaja_sin_convertirse_en_etiqueta(self) -> None:
        """FMP manda la fecha de cierre pero no la etiqueta del trimestre. Se pasa como fecha: leer
        "Q2" de un cierre en junio le inventaría el calendario fiscal a la empresa — el trimestre
        que cierra en junio es el Q3 de varias.
        """

        event = build_earnings_event(
            {
                "symbol": "NVDA",
                "date": "2026-08-27",
                "fiscalDateEnding": "2026-07-31",
            }
        )

        assert event is not None
        assert event.fiscal_period_end == date(2026, 7, 31)
        assert event.fiscal_period is None

    def test_sin_reportados_queda_programado(self) -> None:
        event = build_earnings_event(
            {"symbol": "AAPL", "date": "2026-10-30", "epsEstimated": 2.1}
        )

        assert event is not None
        assert event.status is EarningsStatus.SCHEDULED
        assert event.eps_actual is None
        assert event.surprise_direction is SurpriseDirection.UNKNOWN

    def test_una_fecha_pasada_sin_numeros_sigue_programada(self) -> None:
        """El estado sale de si HAY datos, no de si la fecha pasó: un balance de ayer sin números
        cargados no tiene nada que el usuario pueda leer.
        """

        event = build_earnings_event({"symbol": "AAPL", "date": "2020-01-15"})
        assert event is not None
        assert event.status is EarningsStatus.SCHEDULED

    def test_sin_simbolo_o_sin_fecha_se_descarta(self) -> None:
        # Un balance que no se puede ubicar en el calendario ensuciaría la lista con una fila
        # inutilizable.
        assert build_earnings_event({"date": "2026-08-27"}) is None
        assert build_earnings_event({"symbol": "NVDA"}) is None
        assert build_earnings_event({"symbol": "  ", "date": "2026-08-27"}) is None

    def test_valores_no_numericos_quedan_en_none(self) -> None:
        event = build_earnings_event(
            {"symbol": "NVDA", "date": "2026-08-27", "eps": "n/a", "revenue": None}
        )
        assert event is not None
        assert event.eps_actual is None
        assert event.revenue_actual is None

    def test_los_numeros_como_texto_se_parsean(self) -> None:
        event = build_earnings_event(
            {
                "symbol": "NVDA",
                "date": "2026-08-27",
                "epsEstimated": "1.0",
                "eps": "1.5",
            }
        )
        assert event is not None
        assert event.eps_surprise == pytest.approx(0.5)


class TestParseSession:
    @pytest.mark.parametrize(
        ("raw", "expected"),
        [
            ("bmo", EarningsSession.BMO),
            ("BMO", EarningsSession.BMO),
            ("Before Market Open", EarningsSession.BMO),
            ("amc", EarningsSession.AMC),
            ("After Market Close", EarningsSession.AMC),
            ("dmh", EarningsSession.DURING),
        ],
    )
    def test_reconoce_los_alias(self, raw: str, expected: EarningsSession) -> None:
        assert parse_session(raw) is expected

    def test_lo_desconocido_cae_a_unknown_y_no_a_un_default_optimista(self) -> None:
        """Suponer BMO haría que alguien planifique una operación para la apertura sobre un dato
        inventado.
        """

        assert parse_session(None) is EarningsSession.UNKNOWN
        assert parse_session("") is EarningsSession.UNKNOWN
        assert parse_session("cuando sea") is EarningsSession.UNKNOWN
        assert parse_session(123) is EarningsSession.UNKNOWN


class TestParseFilingType:
    def test_normaliza_los_tres_tipos_conocidos(self) -> None:
        assert parse_filing_type("10-K") is FilingType.TEN_K
        assert parse_filing_type("10-Q") is FilingType.TEN_Q
        assert parse_filing_type("8-K") is FilingType.EIGHT_K
        assert parse_filing_type("10k") is FilingType.TEN_K

    def test_una_enmienda_no_se_normaliza_al_reporte_original(self) -> None:
        """ "10-K/A" es un documento distinto de un 10-K. Normalizarlo borraría esa diferencia; cae a
        OTHER, que es honesto, y `raw_type` conserva la forma exacta.
        """

        assert parse_filing_type("10-K/A") is FilingType.OTHER

    def test_lo_desconocido_es_other_y_no_se_esconde(self) -> None:
        assert parse_filing_type("DEF 14A") is FilingType.OTHER
        assert parse_filing_type(None) is FilingType.OTHER


# --- Clasificación de noticias ----------------------------------------------------------------------


class TestClassifyCategory:
    def test_un_rumor_gana_sobre_la_noticia_corporativa(self) -> None:
        """Es la regla de orden más importante: una versión sin confirmar sobre una adquisición es
        antes un rumor que una noticia corporativa. Mezclarla con los hechos confirmados es
        exactamente el error que esta categoría existe para evitar.
        """

        assert (
            classify_category("NVDA reportedly in talks to acquire a chip startup")
            is NewsCategory.RUMOR
        )
        assert (
            classify_category("Según fuentes, la empresa evalúa una fusión")
            is NewsCategory.RUMOR
        )

    def test_lo_regulatorio_gana_sobre_el_balance(self) -> None:
        # Una demanda de la SEC sobre el reporte trimestral es un problema regulatorio, no un
        # balance.
        assert (
            classify_category("SEC opens investigation into quarterly earnings report")
            is NewsCategory.REGULATORY
        )

    def test_reconoce_balances_y_corporativas(self) -> None:
        assert (
            classify_category("NVDA posts record quarterly earnings")
            is NewsCategory.EARNINGS
        )
        assert (
            classify_category("La compañía anuncia la recompra de acciones")
            is NewsCategory.CORPORATE
        )

    def test_el_resto_es_market_explicito(self) -> None:
        # Explícito y no un `None` disfrazado: el cliente siempre tiene una categoría que mostrar.
        assert classify_category("Wall Street cierra mixto") is NewsCategory.MARKET

    def test_los_acentos_no_cambian_la_clasificacion(self) -> None:
        assert classify_category("Anuncian una adquisición") is NewsCategory.CORPORATE
        assert classify_category("Anuncian una adquisicion") is NewsCategory.CORPORATE

    def test_el_resumen_tambien_cuenta(self) -> None:
        assert (
            classify_category("Novedades de la empresa", "Se confirmó una demanda")
            is NewsCategory.REGULATORY
        )


class TestClassifySentiment:
    def test_detecta_las_dos_direcciones(self) -> None:
        assert (
            classify_sentiment("NVDA beats estimates and hits record revenue")
            is NewsSentiment.BULLISH
        )
        assert (
            classify_sentiment("Shares plunge after guidance downgrade")
            is NewsSentiment.BEARISH
        )

    def test_un_titular_con_senales_en_ambas_direcciones_es_neutral(self) -> None:
        """Un empate no se fuerza a un lado: "recorta costos y supera estimaciones" no es alcista ni
        bajista, e inclinarlo inventaría una conclusión que el texto no da.
        """

        assert (
            classify_sentiment("La empresa recorta personal pero supera estimaciones")
            is NewsSentiment.NEUTRAL
        )

    def test_sin_senales_es_neutral(self) -> None:
        assert (
            classify_sentiment("La empresa presentó su reporte")
            is NewsSentiment.NEUTRAL
        )


class TestNewsHelpers:
    def test_el_id_es_estable_y_deriva_de_la_url(self) -> None:
        # El cliente lo usa para marcar lo ya leído: un id aleatorio lo rompería en cada refresco.
        first = news_ref_id("https://reuters.com/a", "Un título")
        second = news_ref_id("https://reuters.com/a", "Otro título distinto")
        assert first == second
        assert first != news_ref_id("https://reuters.com/b", "Un título")

    def test_sin_url_cae_al_titulo(self) -> None:
        assert news_ref_id(None, "Título") == news_ref_id(None, "Título")

    def test_extrae_el_dominio_sin_www(self) -> None:
        assert extract_source("https://www.reuters.com/markets/x") == "reuters.com"
        assert extract_source("https://bloomberg.com/x") == "bloomberg.com"
        assert extract_source(None) is None
        assert extract_source("no-es-url") is None


# --- Servicio: calendario ----------------------------------------------------------------------------


class TestEarningsCalendarService:
    async def test_sin_fmp_devuelve_estructura_valida_con_el_motivo(self) -> None:
        result = await _service().get_earnings_calendar(
            from_date=date(2026, 8, 1), to_date=date(2026, 8, 8)
        )

        assert result.events == []
        assert result.availability is DataAvailability.UNAVAILABLE
        assert result.degradation_reason == REASON_NO_FMP

    async def test_lo_que_cae_afuera_del_rango_no_entra(self) -> None:
        """El rango de la respuesta es una AFIRMACIÓN, no una sugerencia.

        Un proveedor que devuelve una fila del 27/08 para un pedido de "10/08 al 17/08" haría que el
        cliente muestre ese balance debajo de un encabezado que dice otra cosa, y la pantalla se
        contradiría sola.
        """

        service = _service(
            fmp_client=_FakeFMP(
                calendar_rows=[
                    {"symbol": "AAPL", "date": "2026-08-11"},
                    {"symbol": "NVDA", "date": "2026-08-27"},
                    {"symbol": "KO", "date": "2026-08-01"},
                ]
            )
        )

        result = await service.get_earnings_calendar(
            from_date=date(2026, 8, 10), to_date=date(2026, 8, 17)
        )

        assert [event.ticker for event in result.events] == ["AAPL"]
        # Los descartados por fecha NO se cuentan como excluidos por sector: ese contador explica un
        # filtro que el usuario puso, y esto es una corrección del rango que el usuario ya pidió.
        assert result.unclassified_by_sector == 0

    async def test_los_extremos_del_rango_son_inclusivos(self) -> None:
        service = _service(
            fmp_client=_FakeFMP(
                calendar_rows=[
                    {"symbol": "AAPL", "date": "2026-08-10"},
                    {"symbol": "NVDA", "date": "2026-08-17"},
                ]
            )
        )

        result = await service.get_earnings_calendar(
            from_date=date(2026, 8, 10), to_date=date(2026, 8, 17)
        )

        assert [event.ticker for event in result.events] == ["AAPL", "NVDA"]

    async def test_un_fallo_del_proveedor_se_distingue_de_no_tener_datos(self) -> None:
        """Las dos respuestas tienen `events: []`. Lo único que las distingue es `availability` y el
        motivo — sin eso, "esta semana no reporta nadie" se lee como una falla.
        """

        failing = _service(fmp_client=_FakeFMP(status=DataStatus.ERROR_API))
        empty = _service(fmp_client=_FakeFMP(calendar_rows=[]))

        failed = await failing.get_earnings_calendar(
            from_date=date(2026, 8, 1), to_date=date(2026, 8, 8)
        )
        no_data = await empty.get_earnings_calendar(
            from_date=date(2026, 8, 1), to_date=date(2026, 8, 8)
        )

        assert failed.availability is DataAvailability.UNAVAILABLE
        assert failed.degradation_reason == REASON_FMP_FAILED
        assert no_data.availability is DataAvailability.AVAILABLE
        assert no_data.degradation_reason is None
        assert no_data.events == []

    async def test_ordena_por_fecha_y_despues_por_simbolo(self) -> None:
        service = _service(
            fmp_client=_FakeFMP(
                calendar_rows=[
                    {"symbol": "MSFT", "date": "2026-08-05"},
                    {"symbol": "AAPL", "date": "2026-08-05"},
                    {"symbol": "NVDA", "date": "2026-08-03"},
                ]
            )
        )

        result = await service.get_earnings_calendar(
            from_date=date(2026, 8, 1), to_date=date(2026, 8, 8)
        )

        assert [event.ticker for event in result.events] == ["NVDA", "AAPL", "MSFT"]

    async def test_filtra_por_ticker(self) -> None:
        service = _service(
            fmp_client=_FakeFMP(
                calendar_rows=[
                    {"symbol": "NVDA", "date": "2026-08-03"},
                    {"symbol": "AAPL", "date": "2026-08-04"},
                ]
            )
        )

        result = await service.get_earnings_calendar(
            from_date=date(2026, 8, 1), to_date=date(2026, 8, 8), ticker="nvda"
        )

        assert [event.ticker for event in result.events] == ["NVDA"]

    async def test_los_simbolos_sin_sector_conocido_quedan_afuera_y_se_cuentan(
        self,
    ) -> None:
        """Sin el sector no se puede afirmar que un símbolo pertenezca al que se pidió. Descartarlos
        en silencio haría leer la lista corta como "esta semana no reporta nadie más del sector".
        """

        service = _service(
            fmp_client=_FakeFMP(
                calendar_rows=[
                    {"symbol": "NVDA", "date": "2026-08-03"},
                    {"symbol": "AAPL", "date": "2026-08-04"},
                    {"symbol": "DESCONOCIDA", "date": "2026-08-05"},
                ]
            )
        )

        result = await service.get_earnings_calendar(
            from_date=date(2026, 8, 1),
            to_date=date(2026, 8, 8),
            sector_tickers=frozenset({"NVDA", "AAPL"}),
        )

        assert [event.ticker for event in result.events] == ["NVDA", "AAPL"]
        assert result.unclassified_by_sector == 1

    async def test_la_cache_sirve_el_rango_y_los_filtros_se_aplican_encima(
        self,
    ) -> None:
        """La caché guarda el rango SIN filtrar: mirar "toda la semana" y después "solo NVDA" tiene
        que ser una sola llamada al proveedor.
        """

        fmp = _FakeFMP(
            calendar_rows=[
                {"symbol": "NVDA", "date": "2026-08-03"},
                {"symbol": "AAPL", "date": "2026-08-04"},
            ]
        )
        service = _service(fmp_client=fmp)

        full = await service.get_earnings_calendar(
            from_date=date(2026, 8, 1), to_date=date(2026, 8, 8)
        )
        filtered = await service.get_earnings_calendar(
            from_date=date(2026, 8, 1), to_date=date(2026, 8, 8), ticker="NVDA"
        )

        assert fmp.calendar_calls == 1
        assert full.served_from_cache is False
        assert filtered.served_from_cache is True
        assert len(filtered.events) == 1

    async def test_un_rango_distinto_es_otra_llamada(self) -> None:
        fmp = _FakeFMP(calendar_rows=[{"symbol": "NVDA", "date": "2026-08-03"}])
        service = _service(fmp_client=fmp)

        await service.get_earnings_calendar(
            from_date=date(2026, 8, 1), to_date=date(2026, 8, 8)
        )
        await service.get_earnings_calendar(
            from_date=date(2026, 9, 1), to_date=date(2026, 9, 8)
        )

        assert fmp.calendar_calls == 2

    async def test_un_fallo_no_se_cachea(self) -> None:
        """Cachear un fallo lo congelaría por una hora: el proveedor se recupera en segundos y el
        usuario seguiría viendo el aviso.
        """

        fmp = _FakeFMP(status=DataStatus.ERROR_API)
        service = _service(fmp_client=fmp)

        await service.get_earnings_calendar(
            from_date=date(2026, 8, 1), to_date=date(2026, 8, 8)
        )
        await service.get_earnings_calendar(
            from_date=date(2026, 8, 1), to_date=date(2026, 8, 8)
        )

        assert fmp.calendar_calls == 2

    async def test_la_cache_expira(self) -> None:
        fmp = _FakeFMP(calendar_rows=[{"symbol": "NVDA", "date": "2026-08-03"}])
        service = _service(fmp_client=fmp, calendar_ttl_seconds=0.0)

        await service.get_earnings_calendar(
            from_date=date(2026, 8, 1), to_date=date(2026, 8, 8)
        )
        second = await service.get_earnings_calendar(
            from_date=date(2026, 8, 1), to_date=date(2026, 8, 8)
        )

        assert fmp.calendar_calls == 2
        assert second.served_from_cache is False


# --- Servicio: histórico -----------------------------------------------------------------------------


class TestEarningsHistoryService:
    async def test_sin_fmp_degrada_con_el_motivo(self) -> None:
        result = await _service().get_earnings_history("NVDA")

        assert result.ticker == "NVDA"
        assert result.quarters == []
        assert result.availability is DataAvailability.UNAVAILABLE
        assert result.degradation_reason == REASON_NO_FMP

    async def test_devuelve_los_trimestres_del_mas_reciente_al_mas_viejo(self) -> None:
        service = _service(
            fmp_client=_FakeFMP(
                history_rows=[
                    {
                        "symbol": "NVDA",
                        "date": "2025-11-01",
                        "epsEstimated": 0.8,
                        "eps": 0.9,
                    },
                    {
                        "symbol": "NVDA",
                        "date": "2026-05-01",
                        "epsEstimated": 1.0,
                        "eps": 1.3,
                    },
                    {
                        "symbol": "NVDA",
                        "date": "2026-02-01",
                        "epsEstimated": 1.0,
                        "eps": 1.1,
                    },
                ]
            )
        )

        result = await service.get_earnings_history("nvda")

        # Es el orden en que se lee un track record.
        assert [q.event_date for q in result.quarters] == [
            date(2026, 5, 1),
            date(2026, 2, 1),
            date(2025, 11, 1),
        ]
        assert result.beat_count == 3
        assert result.measured_quarters == 3
        assert result.beat_rate == pytest.approx(1.0)

    async def test_los_trimestres_sin_reportar_no_entran_al_historico(self) -> None:
        """El histórico es de lo ya publicado. Un balance futuro con estimación no es parte del track
        record y contarlo lo diluiría.
        """

        service = _service(
            fmp_client=_FakeFMP(
                history_rows=[
                    {
                        "symbol": "NVDA",
                        "date": "2026-05-01",
                        "epsEstimated": 1.0,
                        "eps": 1.3,
                    },
                    {"symbol": "NVDA", "date": "2026-11-01", "epsEstimated": 1.5},
                ]
            )
        )

        result = await service.get_earnings_history("NVDA")

        assert len(result.quarters) == 1

    async def test_sin_trimestres_medidos_la_tasa_es_none(self) -> None:
        service = _service(fmp_client=_FakeFMP(history_rows=[]))

        result = await service.get_earnings_history("NVDA")

        # `None` y no 0.0: "no se pudo medir" y "nunca superó una estimación" son cosas distintas.
        assert result.beat_rate is None
        assert result.availability is DataAvailability.AVAILABLE

    async def test_la_segunda_lectura_viene_de_la_cache(self) -> None:
        fmp = _FakeFMP(
            history_rows=[
                {
                    "symbol": "NVDA",
                    "date": "2026-05-01",
                    "epsEstimated": 1.0,
                    "eps": 1.3,
                }
            ]
        )
        service = _service(fmp_client=fmp)

        first = await service.get_earnings_history("NVDA")
        second = await service.get_earnings_history("NVDA")

        assert fmp.history_calls == 1
        assert first.served_from_cache is False
        assert second.served_from_cache is True

    async def test_un_limite_distinto_es_otra_entrada(self) -> None:
        fmp = _FakeFMP(
            history_rows=[
                {
                    "symbol": "NVDA",
                    "date": "2026-05-01",
                    "epsEstimated": 1.0,
                    "eps": 1.3,
                }
            ]
        )
        service = _service(fmp_client=fmp)

        await service.get_earnings_history("NVDA", limit=4)
        await service.get_earnings_history("NVDA", limit=8)

        assert fmp.history_calls == 2


# --- Servicio: filings --------------------------------------------------------------------------------


class TestFilingsService:
    async def test_sin_fmp_degrada_con_el_motivo(self) -> None:
        result = await _service().get_filings("NVDA")

        assert result.filings == []
        assert result.availability is DataAvailability.UNAVAILABLE
        assert result.degradation_reason == REASON_NO_FMP

    async def test_lista_los_reportes_normalizados_conservando_el_tipo_crudo(
        self,
    ) -> None:
        service = _service(
            fmp_client=_FakeFMP(
                filings=[_filing("10-K"), _filing("8-K"), _filing("10-K/A")]
            )
        )

        result = await service.get_filings("nvda")

        assert [f.filing_type for f in result.filings] == [
            FilingType.TEN_K,
            FilingType.EIGHT_K,
            FilingType.OTHER,
        ]
        # La enmienda conserva su forma exacta aunque el tipo normalizado sea OTHER.
        assert result.filings[2].raw_type == "10-K/A"
        assert result.filings[0].url == "https://sec.example/filing"
        assert result.availability is DataAvailability.AVAILABLE

    async def test_un_fallo_del_proveedor_no_se_lee_como_biblioteca_vacia(self) -> None:
        """ "Esta empresa no presentó nada ante la SEC" es falso de cualquier empresa que cotiza. La
        lista vacía por un fallo tiene que declararse, igual que en el calendario.
        """

        service = _service(fmp_client=_FakeFMP(status=DataStatus.ERROR_API))

        result = await service.get_filings("NVDA")

        assert result.filings == []
        assert result.availability is DataAvailability.UNAVAILABLE
        assert result.degradation_reason == REASON_FMP_FAILED

    async def test_un_fallo_del_proveedor_no_se_cachea(self) -> None:
        """El proveedor se recupera en segundos; cachear el fallo lo convierte en una hora de
        biblioteca vacía.
        """

        fmp = _FakeFMP(status=DataStatus.ERROR_API)
        service = _service(fmp_client=fmp)

        await service.get_filings("NVDA")
        await service.get_filings("NVDA")

        assert fmp.filings_calls == 2

    async def test_una_biblioteca_realmente_vacia_se_reporta_disponible(self) -> None:
        """La otra mitad del contrato: sin reportes pero con el proveedor sano, la respuesta es
        AVAILABLE y sin motivo — "no hay" es un dato, no una falla.
        """

        result = await _service(fmp_client=_FakeFMP(filings=[])).get_filings("NVDA")

        assert result.filings == []
        assert result.availability is DataAvailability.AVAILABLE
        assert result.degradation_reason is None

    async def test_sin_pedir_sintesis_no_se_llama_al_modelo(self) -> None:
        """La síntesis es opt-in porque cuesta una llamada: abrir la biblioteca para ver qué presentó
        una empresa no debería gastarla.
        """

        gemini = _FakeGemini(raw_json_text='{"summaries": []}')
        service = _service(
            fmp_client=_FakeFMP(filings=[_filing()]), gemini_client=gemini
        )

        result = await service.get_filings("NVDA")

        assert gemini.calls == 0
        assert result.filings[0].summary is None
        assert result.filings[0].summary_available is False
        assert result.summary_degradation_reason is None

    async def test_con_sintesis_rellena_cada_reporte(self) -> None:
        gemini = _FakeGemini(
            raw_json_text=(
                '{"summaries": ['
                '{"index": 0, "summary": "Reporte anual: buscá el segmento de data center."},'
                '{"index": 1, "summary": "Hecho relevante del 21/02."}'
                "]}"
            )
        )
        service = _service(
            fmp_client=_FakeFMP(filings=[_filing("10-K"), _filing("8-K")]),
            gemini_client=gemini,
        )

        result = await service.get_filings("NVDA", summarize=True)

        assert gemini.calls == 1
        assert result.filings[0].summary_available is True
        assert "data center" in (result.filings[0].summary or "")
        assert result.filings[1].summary_available is True
        assert result.summary_degradation_reason is None

    async def test_sin_gemini_los_reportes_se_listan_igual(self) -> None:
        """La lista llegó perfecta y la síntesis no: por eso el motivo va en un campo aparte del
        general. Un solo campo obligaría a elegir cuál de las dos cosas contar.
        """

        service = _service(fmp_client=_FakeFMP(filings=[_filing()]))

        result = await service.get_filings("NVDA", summarize=True)

        assert len(result.filings) == 1
        assert result.availability is DataAvailability.AVAILABLE
        assert result.degradation_reason is None
        assert result.summary_degradation_reason == REASON_NO_GEMINI_SUMMARY

    async def test_un_fallo_del_modelo_no_tira_la_lista(self) -> None:
        service = _service(
            fmp_client=_FakeFMP(filings=[_filing()]),
            gemini_client=_FakeGemini(raw_json_text=None, status=DataStatus.ERROR_API),
        )

        result = await service.get_filings("NVDA", summarize=True)

        assert len(result.filings) == 1
        assert result.summary_degradation_reason == REASON_GEMINI_SUMMARY_FAILED

    async def test_una_respuesta_ilegible_del_modelo_se_trata_como_fallo(self) -> None:
        service = _service(
            fmp_client=_FakeFMP(filings=[_filing()]),
            gemini_client=_FakeGemini(raw_json_text="esto no es json"),
        )

        result = await service.get_filings("NVDA", summarize=True)

        assert result.summary_degradation_reason == REASON_GEMINI_SUMMARY_FAILED
        assert result.filings[0].summary_available is False

    async def test_una_sintesis_vacia_no_se_presenta_como_disponible(self) -> None:
        """El modelo respondió con forma válida pero sin sintetizar nada. Devolver
        `summary_available=True` con el campo en blanco sería peor que declarar el fallo.
        """

        service = _service(
            fmp_client=_FakeFMP(filings=[_filing()]),
            gemini_client=_FakeGemini(raw_json_text='{"summaries": []}'),
        )

        result = await service.get_filings("NVDA", summarize=True)

        assert result.summary_degradation_reason == REASON_GEMINI_SUMMARY_FAILED

    async def test_una_sintesis_parcial_conserva_las_que_si_llegaron(self) -> None:
        """Que el modelo se saltee un reporte no debería tirar los otros."""

        service = _service(
            fmp_client=_FakeFMP(filings=[_filing("10-K"), _filing("8-K")]),
            gemini_client=_FakeGemini(
                raw_json_text='{"summaries": [{"index": 0, "summary": "Solo esta."}]}'
            ),
        )

        result = await service.get_filings("NVDA", summarize=True)

        assert result.filings[0].summary_available is True
        assert result.filings[1].summary_available is False
        assert result.summary_degradation_reason is None

    async def test_la_lista_se_cachea_pero_la_sintesis_no_se_saltea(self) -> None:
        """La caché guarda los METADATOS. Pedir la síntesis después no puede devolver la copia sin
        sintetizar.
        """

        fmp = _FakeFMP(filings=[_filing()])
        gemini = _FakeGemini(
            raw_json_text='{"summaries": [{"index": 0, "summary": "Reporte anual."}]}'
        )
        service = _service(fmp_client=fmp, gemini_client=gemini)

        plain = await service.get_filings("NVDA")
        summarized = await service.get_filings("NVDA", summarize=True)

        assert fmp.filings_calls == 1
        assert plain.filings[0].summary_available is False
        assert summarized.filings[0].summary_available is True

    async def test_la_sintesis_no_contamina_la_entrada_cacheada(self) -> None:
        """El servicio copia los reportes antes de anotarlos. Sin la copia, la síntesis quedaría
        pegada en la caché y una lectura posterior SIN `summarize` la devolvería igual.
        """

        service = _service(
            fmp_client=_FakeFMP(filings=[_filing()]),
            gemini_client=_FakeGemini(
                raw_json_text='{"summaries": [{"index": 0, "summary": "Reporte anual."}]}'
            ),
        )

        await service.get_filings("NVDA", summarize=True)
        plain = await service.get_filings("NVDA")

        assert plain.filings[0].summary is None
        assert plain.filings[0].summary_available is False


# --- Servicio: noticias --------------------------------------------------------------------------------


class TestNewsService:
    async def test_sin_tavily_degrada_con_el_motivo(self) -> None:
        result = await _service().get_news()

        assert result.items == []
        assert result.availability is DataAvailability.UNAVAILABLE
        assert result.degradation_reason == REASON_NO_TAVILY

    async def test_un_fallo_del_buscador_se_declara(self) -> None:
        service = _service(tavily_client=_FakeTavily(status=DataStatus.ERROR_API))

        result = await service.get_news()

        assert result.availability is DataAvailability.UNAVAILABLE
        assert result.degradation_reason == REASON_TAVILY_FAILED

    async def test_usa_el_titular_del_proveedor_y_clasifica(self) -> None:
        service = _service(
            tavily_client=_FakeTavily(
                articles=[
                    _article(
                        title="NVDA beats estimates with record revenue",
                        excerpt="La compañía reportó ingresos récord en el trimestre.",
                    )
                ]
            )
        )

        result = await service.get_news(ticker="nvda")

        item = result.items[0]
        # El titular del proveedor, no la primera línea del cuerpo.
        assert item.title == "NVDA beats estimates with record revenue"
        assert item.source == "reuters.com"
        assert item.category is NewsCategory.EARNINGS
        assert item.sentiment is NewsSentiment.BULLISH
        # Siempre declara que la clasificación es un heurístico, no el veredicto de un analista.
        assert item.classification_source.value == "KEYWORD"
        assert item.tickers == ["NVDA"]

    async def test_sin_titular_cae_a_la_primera_linea_del_cuerpo(self) -> None:
        service = _service(
            tavily_client=_FakeTavily(
                articles=[
                    EvidenceItem(
                        ref_id="t:1",
                        source_type="NEWS",
                        url="https://reuters.com/x",
                        published_at=None,
                        excerpt="Primera línea del cuerpo.\nSegunda línea.",
                    )
                ]
            )
        )

        result = await service.get_news()

        assert result.items[0].title == "Primera línea del cuerpo."

    async def test_filtra_por_categoria_y_por_sentimiento(self) -> None:
        service = _service(
            tavily_client=_FakeTavily(
                articles=[
                    _article(title="NVDA beats estimates", url="https://a.com/1"),
                    _article(
                        title="SEC opens investigation into the company",
                        url="https://b.com/2",
                    ),
                    _article(
                        title="Reportedly in talks to acquire a rival",
                        url="https://c.com/3",
                    ),
                ]
            )
        )

        rumors = await service.get_news(category=NewsCategory.RUMOR)
        bearish = await service.get_news(sentiment=NewsSentiment.BEARISH)

        assert [item.category for item in rumors.items] == [NewsCategory.RUMOR]
        assert all(item.sentiment is NewsSentiment.BEARISH for item in bearish.items)
        # `total_before_filters` deja decir "1 de 3" en vez de solo "1".
        assert rumors.total_before_filters == 3
        assert rumors.total == 1

    async def test_los_filtros_se_declaran_en_la_respuesta(self) -> None:
        """Con tres filtros combinables, una lista corta es ambigua: sin esto el cliente no puede
        distinguir "no hay noticias" de "el filtro dejó una sola".
        """

        service = _service(tavily_client=_FakeTavily(articles=[]))

        result = await service.get_news(
            ticker="nvda",
            category=NewsCategory.RUMOR,
            sentiment=NewsSentiment.BEARISH,
        )

        assert result.applied_ticker == "NVDA"
        assert result.applied_category is NewsCategory.RUMOR
        assert result.applied_sentiment is NewsSentiment.BEARISH

    async def test_ordena_por_fecha_y_las_sin_fecha_van_al_final(self) -> None:
        """No se puede afirmar que una nota sin fecha sea la más nueva."""

        now = datetime.now(timezone.utc)
        service = _service(
            tavily_client=_FakeTavily(
                articles=[
                    _article(
                        title="Vieja",
                        url="https://a.com/1",
                        published_at=now - timedelta(days=3),
                    ),
                    EvidenceItem(
                        ref_id="t:2",
                        source_type="NEWS",
                        url="https://b.com/2",
                        published_at=None,
                        excerpt="Sin fecha",
                        title="Sin fecha",
                    ),
                    _article(title="Nueva", url="https://c.com/3", published_at=now),
                ]
            )
        )

        result = await service.get_news()

        assert [item.title for item in result.items] == ["Nueva", "Vieja", "Sin fecha"]

    async def test_cambiar_de_filtro_no_gasta_una_busqueda_nueva(self) -> None:
        """La caché guarda el feed SIN filtrar: los dos filtros se resuelven en código sobre los
        mismos ítems, así que cambiar de pestaña en la UI no cuesta un request.
        """

        tavily = _FakeTavily(
            articles=[
                _article(title="NVDA beats estimates", url="https://a.com/1"),
                _article(title="Reportedly in talks", url="https://b.com/2"),
            ]
        )
        service = _service(tavily_client=tavily)

        await service.get_news(ticker="NVDA")
        filtered = await service.get_news(ticker="NVDA", category=NewsCategory.RUMOR)

        assert tavily.calls == 1
        assert filtered.served_from_cache is True
        assert filtered.total == 1

    async def test_cada_ticker_tiene_su_entrada_de_cache(self) -> None:
        tavily = _FakeTavily(articles=[_article(title="Algo")])
        service = _service(tavily_client=tavily)

        await service.get_news(ticker="NVDA")
        await service.get_news(ticker="AAPL")

        assert tavily.calls == 2

    async def test_un_fallo_del_buscador_no_se_cachea(self) -> None:
        tavily = _FakeTavily(status=DataStatus.ERROR_API)
        service = _service(tavily_client=tavily)

        await service.get_news()
        await service.get_news()

        assert tavily.calls == 2

    async def test_respeta_el_limite(self) -> None:
        service = _service(
            tavily_client=_FakeTavily(
                articles=[
                    _article(title=f"Nota {index}", url=f"https://a.com/{index}")
                    for index in range(10)
                ]
            )
        )

        result = await service.get_news(limit=3)

        assert result.total == 3
        assert result.total_before_filters == 10

    async def test_la_entrada_cacheada_sirve_a_un_limite_mayor(self) -> None:
        """La caché guarda el feed del tope configurado, no el del primero que llamó: si guardara el
        del primero, quien después pida más ítems recibiría menos y `total_before_filters` le
        reportaría el total de OTRO request.
        """

        tavily = _FakeTavily(
            articles=[
                _article(title=f"Nota {index}", url=f"https://a.com/{index}")
                for index in range(10)
            ]
        )
        service = _service(tavily_client=tavily)

        await service.get_news(limit=2)
        result = await service.get_news(limit=8)

        assert tavily.calls == 1
        assert result.total == 8
        assert result.total_before_filters == 10


# --- Endpoints ---------------------------------------------------------------------------------------


class TestEndpointsAuth:
    async def test_los_cuatro_exigen_autenticacion(
        self, client: httpx.AsyncClient
    ) -> None:
        for path in (
            "/api/v1/corporate/earnings-calendar",
            "/api/v1/corporate/earnings-history/NVDA",
            "/api/v1/corporate/filings/NVDA",
            "/api/v1/corporate/news",
        ):
            assert (await client.get(path)).status_code == 401, path


class TestEndpointsDegradation:
    async def test_sin_credenciales_responden_200_con_estructura_valida(
        self, client: httpx.AsyncClient
    ) -> None:
        """Un 503 obligaría al cliente a traducir "no configurado" a un aviso, y le impediría
        distinguirlo de "esta semana no reporta nadie".
        """

        headers = await _auth(client, "corp-degraded@example.com")

        calendar = await client.get(
            "/api/v1/corporate/earnings-calendar", headers=headers
        )
        history = await client.get(
            "/api/v1/corporate/earnings-history/NVDA", headers=headers
        )
        filings = await client.get("/api/v1/corporate/filings/NVDA", headers=headers)
        news = await client.get("/api/v1/corporate/news", headers=headers)

        for response in (calendar, history, filings, news):
            assert response.status_code == 200, response.text
            body = response.json()
            assert body["availability"] == "UNAVAILABLE"
            assert body["degradation_reason"]

        assert calendar.json()["events"] == []
        assert history.json()["quarters"] == []
        assert filings.json()["filings"] == []
        assert news.json()["items"] == []


class TestEarningsCalendarEndpoint:
    async def test_devuelve_los_eventos_con_el_rango_pedido(
        self, client: httpx.AsyncClient
    ) -> None:
        app.state.corporate_service = _service(
            fmp_client=_FakeFMP(
                calendar_rows=[
                    {
                        "symbol": "NVDA",
                        "date": "2026-08-27",
                        "time": "amc",
                        "epsEstimated": 1.0,
                        "eps": 1.25,
                    }
                ]
            )
        )
        headers = await _auth(client, "corp-cal@example.com")

        response = await client.get(
            "/api/v1/corporate/earnings-calendar",
            params={"from": "2026-08-01", "to": "2026-08-31"},
            headers=headers,
        )

        assert response.status_code == 200
        body = response.json()
        assert body["from_date"] == "2026-08-01"
        assert body["to_date"] == "2026-08-31"
        assert body["availability"] == "AVAILABLE"
        event = body["events"][0]
        assert event["ticker"] == "NVDA"
        assert event["session"] == "AMC"
        assert event["status"] == "REPORTED"
        assert event["surprise_direction"] == "BEAT"
        assert event["eps_surprise_pct"] == pytest.approx(25.0)

    async def test_un_rango_invertido_se_da_vuelta_en_vez_de_rechazarse(
        self, client: httpx.AsyncClient
    ) -> None:
        """Es un error de tipeo cuya intención no es ambigua: devolver un 422 solo agrega un viaje."""

        app.state.corporate_service = _service(fmp_client=_FakeFMP())
        headers = await _auth(client, "corp-range@example.com")

        response = await client.get(
            "/api/v1/corporate/earnings-calendar",
            params={"from": "2026-08-31", "to": "2026-08-01"},
            headers=headers,
        )

        assert response.status_code == 200
        assert response.json()["from_date"] == "2026-08-01"
        assert response.json()["to_date"] == "2026-08-31"

    async def test_un_rango_enorme_se_acota(self, client: httpx.AsyncClient) -> None:
        """Sin el tope, un cliente puede pedir cinco años de balances de todo el mercado."""

        app.state.corporate_service = _service(fmp_client=_FakeFMP())
        headers = await _auth(client, "corp-huge@example.com")

        response = await client.get(
            "/api/v1/corporate/earnings-calendar",
            params={"from": "2026-01-01", "to": "2031-01-01"},
            headers=headers,
        )

        body = response.json()
        span = date.fromisoformat(body["to_date"]) - date.fromisoformat(
            body["from_date"]
        )
        assert span.days <= 92

    async def test_el_filtro_por_sector_usa_el_catalogo_local(
        self, client: httpx.AsyncClient, db_session_factory: Any
    ) -> None:
        from app.models.enums import ExchangeType
        from app.models.ticker import Ticker

        async with db_session_factory() as session:
            session.add_all(
                [
                    Ticker(
                        symbol="NVDA",
                        name="NVIDIA",
                        exchange=ExchangeType.NASDAQ,
                        sector="Technology",
                        active=True,
                    ),
                    Ticker(
                        symbol="JPM",
                        name="JPMorgan",
                        exchange=ExchangeType.NYSE,
                        sector="Financial Services",
                        active=True,
                    ),
                ]
            )
            await session.commit()

        app.state.corporate_service = _service(
            fmp_client=_FakeFMP(
                calendar_rows=[
                    {"symbol": "NVDA", "date": "2026-08-27"},
                    {"symbol": "JPM", "date": "2026-08-28"},
                    {"symbol": "ZZZZ", "date": "2026-08-29"},
                ]
            )
        )
        headers = await _auth(client, "corp-sector@example.com")

        response = await client.get(
            "/api/v1/corporate/earnings-calendar",
            params={"from": "2026-08-01", "to": "2026-08-31", "sector": "tecnologia"},
            headers=headers,
        )

        body = response.json()
        # "tecnologia" (sin acento, en español) encuentra los símbolos que el proveedor marcó como
        # "Technology": quien filtra por uno espera los mismos que quien filtra por el otro.
        assert [event["ticker"] for event in body["events"]] == ["NVDA"]
        # JPM y ZZZZ: uno es de otro sector, el otro no está en el catálogo.
        assert body["unclassified_by_sector"] == 2

    @pytest.mark.parametrize(
        "sector",
        ["Tecnología", "TECNOLOGIA", "Technology", "information technology"],
    )
    async def test_los_dos_vocabularios_de_sector_traen_lo_mismo(
        self, client: httpx.AsyncClient, db_session_factory: Any, sector: str
    ) -> None:
        """El del producto ("Tecnología", el que muestra la UI) y el del proveedor ("Technology", el
        que aparece en la ficha del activo). Aceptar solo uno haría que el mismo filtro funcione en
        una pantalla y devuelva vacío en la otra.
        """

        from app.models.enums import ExchangeType
        from app.models.ticker import Ticker

        async with db_session_factory() as session:
            session.add(
                Ticker(
                    symbol="NVDA",
                    name="NVIDIA",
                    exchange=ExchangeType.NASDAQ,
                    sector="Technology",
                    active=True,
                )
            )
            await session.commit()

        app.state.corporate_service = _service(
            fmp_client=_FakeFMP(
                calendar_rows=[
                    {"symbol": "NVDA", "date": "2026-08-27"},
                    {"symbol": "JPM", "date": "2026-08-28"},
                ]
            )
        )
        headers = await _auth(client, f"corp-vocab-{sector.strip()[:6]}@example.com")

        response = await client.get(
            "/api/v1/corporate/earnings-calendar",
            params={"from": "2026-08-01", "to": "2026-08-31", "sector": sector},
            headers=headers,
        )

        assert [event["ticker"] for event in response.json()["events"]] == ["NVDA"]

    async def test_un_sector_que_nadie_conoce_no_trae_nada(
        self, client: httpx.AsyncClient
    ) -> None:
        """Vacío, no todo el calendario: un filtro que no matchea nada tiene que verse como un
        filtro que no matchea nada, y `unclassified_by_sector` explica por qué.
        """

        app.state.corporate_service = _service(
            fmp_client=_FakeFMP(
                calendar_rows=[{"symbol": "NVDA", "date": "2026-08-27"}]
            )
        )
        headers = await _auth(client, "corp-sector-raro@example.com")

        response = await client.get(
            "/api/v1/corporate/earnings-calendar",
            params={
                "from": "2026-08-01",
                "to": "2026-08-31",
                "sector": "criptomineria",
            },
            headers=headers,
        )

        assert response.json()["events"] == []
        assert response.json()["unclassified_by_sector"] == 1

    async def test_el_ticker_gana_sobre_el_sector(
        self, client: httpx.AsyncClient
    ) -> None:
        """Son dos preguntas distintas y su intersección casi siempre es una fila o ninguna, lo que
        se leería como un bug.
        """

        app.state.corporate_service = _service(
            fmp_client=_FakeFMP(
                calendar_rows=[
                    {"symbol": "NVDA", "date": "2026-08-27"},
                    {"symbol": "JPM", "date": "2026-08-28"},
                ]
            )
        )
        headers = await _auth(client, "corp-both@example.com")

        response = await client.get(
            "/api/v1/corporate/earnings-calendar",
            # El rango va explícito: sin él se usa el default (hoy + 7 días), y las fechas del
            # fixture quedarían afuera del rango — la respuesta descarta lo que no pertenece al
            # rango que declara.
            params={
                "from": "2026-08-20",
                "to": "2026-08-31",
                "ticker": "JPM",
                "sector": "tecnologia",
            },
            headers=headers,
        )

        assert [event["ticker"] for event in response.json()["events"]] == ["JPM"]
        assert response.json()["unclassified_by_sector"] == 0


class TestEarningsHistoryEndpoint:
    async def test_devuelve_el_historico_con_su_estadistica(
        self, client: httpx.AsyncClient
    ) -> None:
        app.state.corporate_service = _service(
            fmp_client=_FakeFMP(
                history_rows=[
                    {
                        "symbol": "NVDA",
                        "date": "2026-05-01",
                        "epsEstimated": 1.0,
                        "eps": 1.2,
                    },
                    {
                        "symbol": "NVDA",
                        "date": "2026-02-01",
                        "epsEstimated": 1.0,
                        "eps": 0.8,
                    },
                ]
            )
        )
        headers = await _auth(client, "corp-hist@example.com")

        response = await client.get(
            "/api/v1/corporate/earnings-history/nvda", headers=headers
        )

        body = response.json()
        assert body["ticker"] == "NVDA"
        assert body["beat_count"] == 1
        assert body["miss_count"] == 1
        assert body["measured_quarters"] == 2
        assert body["average_surprise_pct"] == pytest.approx(0.0)

    async def test_valida_el_limite(self, client: httpx.AsyncClient) -> None:
        headers = await _auth(client, "corp-hist-limit@example.com")

        assert (
            await client.get(
                "/api/v1/corporate/earnings-history/NVDA",
                params={"limit": 0},
                headers=headers,
            )
        ).status_code == 422
        assert (
            await client.get(
                "/api/v1/corporate/earnings-history/NVDA",
                params={"limit": 99},
                headers=headers,
            )
        ).status_code == 422


class TestFilingsEndpoint:
    async def test_lista_los_reportes_sin_sintesis_por_defecto(
        self, client: httpx.AsyncClient
    ) -> None:
        gemini = _FakeGemini(raw_json_text='{"summaries": []}')
        app.state.corporate_service = _service(
            fmp_client=_FakeFMP(filings=[_filing("10-K"), _filing("8-K")]),
            gemini_client=gemini,
        )
        headers = await _auth(client, "corp-filings@example.com")

        response = await client.get("/api/v1/corporate/filings/NVDA", headers=headers)

        body = response.json()
        assert [f["filing_type"] for f in body["filings"]] == ["10-K", "8-K"]
        assert gemini.calls == 0
        assert body["summary_degradation_reason"] is None

    async def test_con_summarize_genera_la_sintesis(
        self, client: httpx.AsyncClient
    ) -> None:
        app.state.corporate_service = _service(
            fmp_client=_FakeFMP(filings=[_filing("10-K")]),
            gemini_client=_FakeGemini(
                raw_json_text=(
                    '{"summaries": [{"index": 0, "summary": "Reporte anual: buscá el '
                    'segmento de data center."}]}'
                )
            ),
        )
        headers = await _auth(client, "corp-filings-sum@example.com")

        response = await client.get(
            "/api/v1/corporate/filings/NVDA",
            params={"summarize": True},
            headers=headers,
        )

        filing = response.json()["filings"][0]
        assert filing["summary_available"] is True
        assert "data center" in filing["summary"]


class TestNewsEndpoint:
    async def test_devuelve_el_feed_clasificado(
        self, client: httpx.AsyncClient
    ) -> None:
        app.state.corporate_service = _service(
            tavily_client=_FakeTavily(
                articles=[
                    _article(
                        title="NVDA reportedly in talks to acquire a rival",
                        url="https://reuters.com/1",
                    )
                ]
            )
        )
        headers = await _auth(client, "corp-news@example.com")

        response = await client.get(
            "/api/v1/corporate/news", params={"ticker": "nvda"}, headers=headers
        )

        body = response.json()
        item = body["items"][0]
        assert item["category"] == "RUMOR"
        assert item["classification_source"] == "KEYWORD"
        assert item["source"] == "reuters.com"
        assert body["applied_ticker"] == "NVDA"
        assert body["total_before_filters"] == 1

    async def test_filtra_por_categoria_y_sentimiento(
        self, client: httpx.AsyncClient
    ) -> None:
        app.state.corporate_service = _service(
            tavily_client=_FakeTavily(
                articles=[
                    _article(title="NVDA beats estimates", url="https://a.com/1"),
                    _article(
                        title="Reportedly weighing a spin-off", url="https://b.com/2"
                    ),
                ]
            )
        )
        headers = await _auth(client, "corp-news-filter@example.com")

        response = await client.get(
            "/api/v1/corporate/news",
            params={"category": "RUMOR"},
            headers=headers,
        )

        body = response.json()
        assert len(body["items"]) == 1
        assert body["items"][0]["category"] == "RUMOR"
        assert body["total_before_filters"] == 2

    async def test_una_categoria_invalida_se_rechaza(
        self, client: httpx.AsyncClient
    ) -> None:
        headers = await _auth(client, "corp-news-bad@example.com")

        response = await client.get(
            "/api/v1/corporate/news",
            params={"category": "CHISMES"},
            headers=headers,
        )

        assert response.status_code == 422
