"""Tests de las reglas de alerta contextuales: `/api/v1/watchlist/alerts` y su evaluación en el
despacho.

Los contratos que este bloque promete y que son fáciles de romper sin darse cuenta:

  1. **Sin reglas se recibe todo.** Estrenar el filtro no puede dejar callados a los usuarios que
     nunca configuraron nada — sería una regresión disfrazada de feature.
  2. **Ante la duda, no se dispara.** Una regla `PRICE` sin variación medida, o una `TREND_BREAK`
     sobre un horizonte que el motor no proyectó, NO matchean: una regla que dispara ante la falta
     de datos convierte "avisame solo si es grave" en "avisame siempre".
  3. **Los tres tipos miran cosas distintas.** El precio mira el movimiento, la severidad mira qué
     pasó, el quiebre mira la proyección — y una alerta que cumple uno puede no cumplir otro.
  4. **Un parámetro de otro tipo se rechaza**, no se ignora: una regla que parece configurada pero
     cuyo parámetro nadie lee es peor que un error de validación.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from decimal import Decimal

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.security import hash_password
from app.models.device_token import DeviceToken
from app.models.enums import (
    AlertRuleType,
    AssetType,
    DevicePlatform,
    TrendBreakDirection,
    TrendHorizon,
)
from app.models.user import User
from app.models.watchlist import WatchlistItem
from app.models.watchlist_alert_rule import WatchlistAlertRule
from app.services.push_service import PushNotificationService
from app.services.watchlist_alert_service import (
    build_evaluation_context,
    rule_matches,
    select_eligible_items,
)
from src.notification.fcm_client import FCMClient
from src.validation.domain_models import (
    AlertSeverity,
    AlertTriggerType,
    AnalysisNarrative,
    AssetClass,
    AssetProjection,
    HorizonScenarios,
    MarketAlert,
    PushNotificationPayload,
    ScenarioOutcome,
)

# --- Helpers -------------------------------------------------------------------------------


def _projection(
    *,
    horizon: str = "MEDIANO_1_6M",
    dominant: str = "BAJISTA",
    probability: float = 65.0,
    confidence: str = "ALTA",
    classification: str = "DETERIORO_FUNDAMENTAL",
) -> AssetProjection:
    others = [label for label in ("ALCISTA", "NEUTRAL", "BAJISTA") if label != dominant]
    remaining = (100 - probability) / 2
    return AssetProjection(
        ticker="NVDA",
        generated_at=datetime.now(timezone.utc),
        source_alert_id="alert-1",
        horizons=[
            HorizonScenarios(
                horizon=horizon,  # type: ignore[arg-type]  # Literal cerrado; el test elige uno válido
                scenarios=[
                    ScenarioOutcome(
                        label=dominant,  # type: ignore[arg-type]
                        probability_pct=Decimal(str(probability)),
                        rationale="Motivo dominante.",
                    ),
                    *(
                        ScenarioOutcome(
                            label=label,  # type: ignore[arg-type]
                            probability_pct=Decimal(str(remaining)),
                            rationale="Motivo alternativo.",
                        )
                        for label in others
                    ),
                ],
                confidence_level=confidence,  # type: ignore[arg-type]
                data_completeness_pct=Decimal(80),
            )
        ],
        classification=classification,  # type: ignore[arg-type]
        classification_confidence_pct=Decimal(70),
    )


def _payload(
    *,
    ticker: str = "NVDA",
    severity: AlertSeverity = AlertSeverity.HIGH,
    projection: AssetProjection | None = None,
) -> PushNotificationPayload:
    return PushNotificationPayload(
        notification_id=str(uuid.uuid4()),
        ticker=ticker,
        asset_type="stock",
        title="Alerta",
        short_summary="Resumen",
        full_analysis_json=projection,
        technical_narrative=AnalysisNarrative(headline="Headline técnico"),
        beginner_narrative=AnalysisNarrative(headline="Headline simple"),
        default_view="technical",
        urgency_level=severity,
        action_url="financiero://asset/NVDA",
        timestamp=datetime.now(timezone.utc),
        push_dispatched=False,
        alert_db_id=None,
    )


def _market_alert(
    *,
    trigger: AlertTriggerType = AlertTriggerType.PRICE_MOVE,
    value: float | None = -6.4,
    severity: AlertSeverity = AlertSeverity.HIGH,
) -> MarketAlert:
    return MarketAlert(
        alert_id="alert-1",
        ticker="NVDA",
        asset_class=AssetClass.EQUITY,
        trigger_type=trigger,
        severity=severity,
        detected_at=datetime.now(timezone.utc),
        trigger_value=Decimal(str(value)) if value is not None else None,
        threshold_breached=Decimal("3.0"),
        requires_deep_research=True,
    )


def _rule(alert_type: AlertRuleType, **kwargs: object) -> WatchlistAlertRule:
    """Regla en memoria, sin base: `rule_matches` es una función pura sobre la fila, así que se la
    puede probar sin persistir nada.
    """

    return WatchlistAlertRule(
        id=uuid.uuid4(),
        watchlist_item_id=uuid.uuid4(),
        alert_type=alert_type,
        enabled=bool(kwargs.pop("enabled", True)),
        require_negative_sentiment=bool(
            kwargs.pop("require_negative_sentiment", False)
        ),
        **kwargs,
    )


# --- Evaluación: PRICE ----------------------------------------------------------------------


def test_price_rule_matches_when_the_move_crosses_the_threshold() -> None:
    context = build_evaluation_context(
        _payload(),
        trigger_type=AlertTriggerType.PRICE_MOVE,
        trigger_value=Decimal("-6.4"),
    )

    assert rule_matches(
        _rule(AlertRuleType.PRICE, threshold_pct=Decimal("5.0")), context
    )
    assert not rule_matches(
        _rule(AlertRuleType.PRICE, threshold_pct=Decimal("8.0")), context
    )


def test_price_rule_uses_absolute_magnitude() -> None:
    """Un umbral del 5% cubre las dos direcciones: quien pide que le avisen de un movimiento
    grande no está pidiendo solo las caídas.
    """

    context = build_evaluation_context(
        _payload(),
        trigger_type=AlertTriggerType.PRICE_MOVE,
        trigger_value=Decimal("7.1"),
    )

    assert rule_matches(
        _rule(AlertRuleType.PRICE, threshold_pct=Decimal("5.0")), context
    )


def test_price_rule_does_not_match_without_a_measured_move() -> None:
    """Una alerta que no nació de un movimiento de precio no cruza ningún umbral de precio: no se
    asume que sí ni se asume cero.
    """

    news_context = build_evaluation_context(
        _payload(), trigger_type=AlertTriggerType.NEWS_SHOCK, trigger_value=None
    )
    blind_context = build_evaluation_context(_payload())

    rule = _rule(AlertRuleType.PRICE, threshold_pct=Decimal("1.0"))
    assert not rule_matches(rule, news_context)
    assert not rule_matches(rule, blind_context)


def test_disabled_rule_never_matches() -> None:
    context = build_evaluation_context(
        _payload(),
        trigger_type=AlertTriggerType.PRICE_MOVE,
        trigger_value=Decimal("-20.0"),
    )

    assert not rule_matches(
        _rule(AlertRuleType.PRICE, threshold_pct=Decimal("1.0"), enabled=False), context
    )


# --- Evaluación: NEWS_SEVERITY --------------------------------------------------------------


def test_news_rule_matches_a_severe_news_shock() -> None:
    context = build_evaluation_context(
        _payload(severity=AlertSeverity.CRITICAL),
        trigger_type=AlertTriggerType.NEWS_SHOCK,
    )

    assert rule_matches(
        _rule(AlertRuleType.NEWS_SEVERITY, min_severity=AlertSeverity.HIGH), context
    )


def test_news_rule_ignores_lower_severity() -> None:
    context = build_evaluation_context(
        _payload(severity=AlertSeverity.MEDIUM),
        trigger_type=AlertTriggerType.NEWS_SHOCK,
    )

    assert not rule_matches(
        _rule(AlertRuleType.NEWS_SEVERITY, min_severity=AlertSeverity.HIGH), context
    )


def test_news_rule_ignores_pure_price_moves() -> None:
    """Quien configuró una alerta por noticia ya tiene `PRICE` para el movimiento: hacerle llegar
    también cada pico de precio volvería redundante a la regla.
    """

    context = build_evaluation_context(
        _payload(severity=AlertSeverity.CRITICAL),
        trigger_type=AlertTriggerType.PRICE_MOVE,
        trigger_value=Decimal("-9.0"),
    )

    assert not rule_matches(
        _rule(AlertRuleType.NEWS_SEVERITY, min_severity=AlertSeverity.HIGH), context
    )


def test_news_rule_with_negative_sentiment_requires_a_negative_reading() -> None:
    rule = _rule(
        AlertRuleType.NEWS_SEVERITY,
        min_severity=AlertSeverity.HIGH,
        require_negative_sentiment=True,
    )

    deterioration = build_evaluation_context(
        _payload(projection=_projection(classification="DETERIORO_FUNDAMENTAL")),
        trigger_type=AlertTriggerType.NEWS_SHOCK,
    )
    emotional_and_bullish = build_evaluation_context(
        _payload(
            projection=_projection(
                horizon="CORTO_1_14D",
                dominant="ALCISTA",
                classification="REACCION_EMOCIONAL",
            )
        ),
        trigger_type=AlertTriggerType.NEWS_SHOCK,
    )

    assert rule_matches(rule, deterioration)
    assert not rule_matches(rule, emotional_and_bullish)


def test_news_rule_with_negative_sentiment_accepts_a_bearish_short_term() -> None:
    """ "Cambio de sentimiento negativo" no es una etiqueta que el motor emita: se deriva de que el
    corto plazo proyecte baja, aunque la clasificación no sea de deterioro.
    """

    context = build_evaluation_context(
        _payload(
            projection=_projection(
                horizon="CORTO_1_14D",
                dominant="BAJISTA",
                classification="REACCION_EMOCIONAL",
            )
        ),
        trigger_type=AlertTriggerType.NEWS_SHOCK,
    )

    assert rule_matches(
        _rule(
            AlertRuleType.NEWS_SEVERITY,
            min_severity=AlertSeverity.HIGH,
            require_negative_sentiment=True,
        ),
        context,
    )


# --- Evaluación: TREND_BREAK ----------------------------------------------------------------


def test_trend_break_matches_the_configured_horizon() -> None:
    context = build_evaluation_context(
        _payload(projection=_projection(horizon="MEDIANO_1_6M", dominant="BAJISTA"))
    )

    assert rule_matches(
        _rule(AlertRuleType.TREND_BREAK, trend_horizon=TrendHorizon.MEDIANO), context
    )
    # El mismo quiebre no dispara una regla configurada sobre otro horizonte.
    assert not rule_matches(
        _rule(AlertRuleType.TREND_BREAK, trend_horizon=TrendHorizon.LARGO), context
    )


def test_trend_break_respects_the_direction() -> None:
    bullish = build_evaluation_context(
        _payload(projection=_projection(dominant="ALCISTA"))
    )

    assert not rule_matches(
        _rule(
            AlertRuleType.TREND_BREAK,
            trend_horizon=TrendHorizon.MEDIANO,
            trend_direction=TrendBreakDirection.BAJISTA,
        ),
        bullish,
    )
    assert rule_matches(
        _rule(
            AlertRuleType.TREND_BREAK,
            trend_horizon=TrendHorizon.MEDIANO,
            trend_direction=TrendBreakDirection.ALCISTA,
        ),
        bullish,
    )


def test_trend_break_any_direction_still_excludes_neutral() -> None:
    """`CUALQUIERA` es "alcista o bajista", no "cualquier cosa": un horizonte neutral es justamente
    la ausencia de un quiebre.
    """

    neutral = build_evaluation_context(
        _payload(projection=_projection(dominant="NEUTRAL"))
    )

    assert not rule_matches(
        _rule(
            AlertRuleType.TREND_BREAK,
            trend_horizon=TrendHorizon.MEDIANO,
            trend_direction=TrendBreakDirection.CUALQUIERA,
        ),
        neutral,
    )


def test_trend_break_ignores_low_confidence_projections() -> None:
    """El motor ya dijo que no tiene datos suficientes para sostener esa proyección; no despierta
    a nadie con ella.
    """

    context = build_evaluation_context(
        _payload(projection=_projection(dominant="BAJISTA", confidence="BAJA"))
    )

    assert not rule_matches(
        _rule(AlertRuleType.TREND_BREAK, trend_horizon=TrendHorizon.MEDIANO), context
    )


def test_trend_break_respects_the_minimum_probability() -> None:
    context = build_evaluation_context(
        _payload(projection=_projection(dominant="BAJISTA", probability=52.0))
    )

    assert rule_matches(
        _rule(
            AlertRuleType.TREND_BREAK,
            trend_horizon=TrendHorizon.MEDIANO,
            min_probability_pct=Decimal(50),
        ),
        context,
    )
    assert not rule_matches(
        _rule(
            AlertRuleType.TREND_BREAK,
            trend_horizon=TrendHorizon.MEDIANO,
            min_probability_pct=Decimal(70),
        ),
        context,
    )


def test_trend_break_does_not_match_without_a_projection() -> None:
    context = build_evaluation_context(_payload(projection=None))

    assert not rule_matches(
        _rule(AlertRuleType.TREND_BREAK, trend_horizon=TrendHorizon.MEDIANO), context
    )


# --- Selección de destinatarios -------------------------------------------------------------


def test_item_without_rules_receives_everything() -> None:
    """La regla de compatibilidad: quien nunca configuró nada sigue recibiendo todo."""

    context = build_evaluation_context(_payload())
    item_id = uuid.uuid4()

    assert select_eligible_items([(item_id, [])], context) == {item_id}


def test_item_with_only_disabled_rules_receives_everything() -> None:
    """Apagar todas las reglas es volver al comportamiento por defecto, no silenciarse: para dejar
    de recibir avisos está no seguir el ticker.
    """

    context = build_evaluation_context(_payload())
    item_id = uuid.uuid4()
    rules = [_rule(AlertRuleType.PRICE, threshold_pct=Decimal("99.0"), enabled=False)]

    assert select_eligible_items([(item_id, rules)], context) == {item_id}


def test_multiple_rules_are_an_or_not_an_and() -> None:
    """Quien configura "precio > 5%" y "noticia grave" pidió las dos cosas por separado, no la
    intersección.
    """

    context = build_evaluation_context(
        _payload(severity=AlertSeverity.CRITICAL),
        trigger_type=AlertTriggerType.NEWS_SHOCK,
    )
    item_id = uuid.uuid4()
    rules = [
        _rule(AlertRuleType.PRICE, threshold_pct=Decimal("5.0")),
        _rule(AlertRuleType.NEWS_SEVERITY, min_severity=AlertSeverity.HIGH),
    ]

    assert select_eligible_items([(item_id, rules)], context) == {item_id}


# --- Despacho -------------------------------------------------------------------------------


async def _seed_watcher(
    session_factory: async_sessionmaker[AsyncSession],
    ticker: str,
    *,
    rules: list[dict[str, object]] | None = None,
    fcm_token: str | None = None,
) -> uuid.UUID:
    async with session_factory() as session:
        user = User(
            email=f"{uuid.uuid4()}@example.com", hashed_password=hash_password("x")
        )
        session.add(user)
        await session.flush()

        item = WatchlistItem(
            user_id=user.id,
            ticker=ticker,
            asset_type=AssetType.STOCK,
            alert_threshold_pct=Decimal("3.0"),
        )
        session.add(item)
        await session.flush()

        for rule in rules or []:
            session.add(
                WatchlistAlertRule(watchlist_item_id=item.id, **rule)  # type: ignore[arg-type]
            )
        if fcm_token is not None:
            session.add(
                DeviceToken(
                    user_id=user.id,
                    fcm_token=fcm_token,
                    platform=DevicePlatform.ANDROID,
                )
            )
        await session.commit()
        return item.id


async def test_dispatch_without_rules_reaches_every_watcher(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_watcher(db_session_factory, "NVDA")
    await _seed_watcher(db_session_factory, "NVDA")
    service = PushNotificationService(db_session_factory)

    result = await service.dispatch_to_watchers(_payload())

    assert result.watcher_count == 2
    assert result.rule_suppressed_count == 0


async def test_dispatch_filters_watchers_whose_rules_do_not_match(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_watcher(
        db_session_factory,
        "NVDA",
        rules=[
            {
                "alert_type": AlertRuleType.PRICE,
                "threshold_pct": Decimal("2.0"),
                "enabled": True,
                "require_negative_sentiment": False,
            }
        ],
    )
    await _seed_watcher(
        db_session_factory,
        "NVDA",
        rules=[
            {
                "alert_type": AlertRuleType.PRICE,
                "threshold_pct": Decimal("15.0"),
                "enabled": True,
                "require_negative_sentiment": False,
            }
        ],
    )
    service = PushNotificationService(db_session_factory)

    result = await service.dispatch_to_watchers(
        _payload(), market_alert=_market_alert(value=-6.4)
    )

    assert result.watcher_count == 2
    # El del umbral del 15% no ve una caída del 6,4%.
    assert result.rule_suppressed_count == 1


async def test_dispatch_without_market_alert_still_evaluates_contextual_rules(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """Sin la `MarketAlert` se pierde la magnitud del movimiento (y con ella las reglas de precio),
    pero la severidad y la proyección viajan en el payload: el filtro degrada en precisión, no en
    entrega.
    """

    await _seed_watcher(
        db_session_factory,
        "NVDA",
        rules=[
            {
                "alert_type": AlertRuleType.TREND_BREAK,
                "trend_horizon": TrendHorizon.MEDIANO,
                "trend_direction": TrendBreakDirection.BAJISTA,
                "min_probability_pct": Decimal(50),
                "enabled": True,
                "require_negative_sentiment": False,
            }
        ],
    )
    service = PushNotificationService(db_session_factory)

    result = await service.dispatch_to_watchers(
        _payload(projection=_projection(dominant="BAJISTA"))
    )

    assert result.rule_suppressed_count == 0


async def test_device_push_only_targets_eligible_users(
    db_session_factory: async_sessionmaker[AsyncSession],
) -> None:
    await _seed_watcher(
        db_session_factory,
        "NVDA",
        fcm_token="token-elegible",
        rules=[
            {
                "alert_type": AlertRuleType.PRICE,
                "threshold_pct": Decimal("2.0"),
                "enabled": True,
                "require_negative_sentiment": False,
            }
        ],
    )
    await _seed_watcher(
        db_session_factory,
        "NVDA",
        fcm_token="token-filtrado",
        rules=[
            {
                "alert_type": AlertRuleType.PRICE,
                "threshold_pct": Decimal("50.0"),
                "enabled": True,
                "require_negative_sentiment": False,
            }
        ],
    )

    sent_tokens: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        sent_tokens.append(request.read().decode("utf-8"))
        return httpx.Response(200, json={"name": "projects/x/messages/1"})

    fcm = FCMClient(
        "project",
        "token",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(handler),
            base_url="https://fcm.googleapis.com",
        ),
    )
    service = PushNotificationService(db_session_factory, fcm_client=fcm)

    await service.dispatch_to_watchers(
        _payload(), market_alert=_market_alert(value=-6.4)
    )

    bodies = "".join(sent_tokens)
    assert "token-elegible" in bodies
    assert "token-filtrado" not in bodies


# --- Endpoint -------------------------------------------------------------------------------


async def _auth_headers(client: httpx.AsyncClient, email: str) -> dict[str, str]:
    await client.post(
        "/api/v1/auth/register", json={"email": email, "password": "supersecreta1"}
    )
    login = await client.post(
        "/api/v1/auth/login", json={"email": email, "password": "supersecreta1"}
    )
    return {"Authorization": f"Bearer {login.json()['access_token']}"}


async def _add_ticker(
    client: httpx.AsyncClient, headers: dict[str, str], ticker: str
) -> None:
    await client.post(
        "/api/v1/watchlist",
        json={"ticker": ticker, "asset_type": "STOCK"},
        headers=headers,
    )


async def test_alert_rules_endpoint_requires_authentication(
    client: httpx.AsyncClient,
) -> None:
    assert (await client.get("/api/v1/watchlist/alerts")).status_code == 401


async def test_create_and_list_price_rule(client: httpx.AsyncClient) -> None:
    headers = await _auth_headers(client, "rules-price@example.com")
    await _add_ticker(client, headers, "NVDA")

    created = await client.post(
        "/api/v1/watchlist/alerts",
        json={"ticker": "nvda", "alert_type": "PRICE", "threshold_pct": "7.5"},
        headers=headers,
    )

    assert created.status_code == 201
    body = created.json()
    assert body["ticker"] == "NVDA"
    assert body["threshold_pct"] == "7.50"
    assert body["enabled"] is True

    listed = await client.get("/api/v1/watchlist/alerts", headers=headers)
    assert listed.status_code == 200
    assert len(listed.json()) == 1


async def test_price_rule_syncs_the_items_threshold(client: httpx.AsyncClient) -> None:
    """Un solo umbral efectivo: `GET /watchlist` no puede mostrar 3% mientras la alerta dispara
    al 9%.
    """

    headers = await _auth_headers(client, "rules-sync@example.com")
    await _add_ticker(client, headers, "NVDA")

    await client.post(
        "/api/v1/watchlist/alerts",
        json={"ticker": "NVDA", "alert_type": "PRICE", "threshold_pct": "9.0"},
        headers=headers,
    )

    items = (await client.get("/api/v1/watchlist", headers=headers)).json()
    assert items[0]["alert_threshold_pct"] == "9.00"


async def test_price_rule_defaults_to_the_users_existing_threshold(
    client: httpx.AsyncClient,
) -> None:
    """Quien venía usando 8% y crea su primera regla explícita no debería encontrarse con que se le
    reseteó al default global.
    """

    headers = await _auth_headers(client, "rules-default@example.com")
    await client.post(
        "/api/v1/watchlist",
        json={"ticker": "NVDA", "asset_type": "STOCK", "alert_threshold_pct": "8.0"},
        headers=headers,
    )

    created = await client.post(
        "/api/v1/watchlist/alerts",
        json={"ticker": "NVDA", "alert_type": "PRICE"},
        headers=headers,
    )

    assert created.json()["threshold_pct"] == "8.00"


async def test_contextual_rules_get_product_defaults(client: httpx.AsyncClient) -> None:
    headers = await _auth_headers(client, "rules-defaults@example.com")
    await _add_ticker(client, headers, "NVDA")

    news = await client.post(
        "/api/v1/watchlist/alerts",
        json={"ticker": "NVDA", "alert_type": "NEWS_SEVERITY"},
        headers=headers,
    )
    trend = await client.post(
        "/api/v1/watchlist/alerts",
        json={"ticker": "NVDA", "alert_type": "TREND_BREAK"},
        headers=headers,
    )

    assert news.json()["min_severity"] == "HIGH"
    assert news.json()["require_negative_sentiment"] is False
    assert trend.json()["trend_horizon"] == "MEDIANO"
    assert trend.json()["trend_direction"] == "BAJISTA"
    assert trend.json()["min_probability_pct"] == "50.00"


async def test_rule_rejects_parameters_of_another_type(
    client: httpx.AsyncClient,
) -> None:
    headers = await _auth_headers(client, "rules-foreign@example.com")
    await _add_ticker(client, headers, "NVDA")

    response = await client.post(
        "/api/v1/watchlist/alerts",
        json={
            "ticker": "NVDA",
            "alert_type": "PRICE",
            "threshold_pct": "5.0",
            "min_severity": "CRITICAL",
        },
        headers=headers,
    )

    assert response.status_code == 422
    assert "min_severity" in response.text


async def test_cannot_create_a_rule_for_an_unfollowed_ticker(
    client: httpx.AsyncClient,
) -> None:
    headers = await _auth_headers(client, "rules-unfollowed@example.com")

    response = await client.post(
        "/api/v1/watchlist/alerts",
        json={"ticker": "TSLA", "alert_type": "PRICE", "threshold_pct": "5.0"},
        headers=headers,
    )

    assert response.status_code == 404
    assert "watchlist" in response.json()["detail"]


async def test_duplicate_rule_type_is_rejected(client: httpx.AsyncClient) -> None:
    headers = await _auth_headers(client, "rules-dupe@example.com")
    await _add_ticker(client, headers, "NVDA")
    payload = {"ticker": "NVDA", "alert_type": "PRICE", "threshold_pct": "5.0"}

    first = await client.post("/api/v1/watchlist/alerts", json=payload, headers=headers)
    second = await client.post(
        "/api/v1/watchlist/alerts", json=payload, headers=headers
    )

    assert first.status_code == 201
    assert second.status_code == 409


async def test_rules_are_filterable_by_ticker_and_type(
    client: httpx.AsyncClient,
) -> None:
    headers = await _auth_headers(client, "rules-filter@example.com")
    await _add_ticker(client, headers, "NVDA")
    await _add_ticker(client, headers, "KO")
    await client.post(
        "/api/v1/watchlist/alerts",
        json={"ticker": "NVDA", "alert_type": "PRICE", "threshold_pct": "5.0"},
        headers=headers,
    )
    await client.post(
        "/api/v1/watchlist/alerts",
        json={"ticker": "NVDA", "alert_type": "TREND_BREAK"},
        headers=headers,
    )
    await client.post(
        "/api/v1/watchlist/alerts",
        json={"ticker": "KO", "alert_type": "NEWS_SEVERITY"},
        headers=headers,
    )

    by_ticker = await client.get(
        "/api/v1/watchlist/alerts", params={"ticker": "NVDA"}, headers=headers
    )
    by_type = await client.get(
        "/api/v1/watchlist/alerts",
        params={"alert_type": "NEWS_SEVERITY"},
        headers=headers,
    )

    assert len(by_ticker.json()) == 2
    assert len(by_type.json()) == 1
    assert by_type.json()[0]["ticker"] == "KO"


async def test_update_rule(client: httpx.AsyncClient) -> None:
    headers = await _auth_headers(client, "rules-patch@example.com")
    await _add_ticker(client, headers, "NVDA")
    created = (
        await client.post(
            "/api/v1/watchlist/alerts",
            json={"ticker": "NVDA", "alert_type": "TREND_BREAK"},
            headers=headers,
        )
    ).json()

    updated = await client.patch(
        f"/api/v1/watchlist/alerts/{created['id']}",
        json={"trend_horizon": "CORTO", "enabled": False},
        headers=headers,
    )

    assert updated.status_code == 200
    assert updated.json()["trend_horizon"] == "CORTO"
    assert updated.json()["enabled"] is False


async def test_update_rejects_parameters_of_another_type(
    client: httpx.AsyncClient,
) -> None:
    headers = await _auth_headers(client, "rules-patch-foreign@example.com")
    await _add_ticker(client, headers, "NVDA")
    created = (
        await client.post(
            "/api/v1/watchlist/alerts",
            json={"ticker": "NVDA", "alert_type": "TREND_BREAK"},
            headers=headers,
        )
    ).json()

    response = await client.patch(
        f"/api/v1/watchlist/alerts/{created['id']}",
        json={"threshold_pct": "5.0"},
        headers=headers,
    )

    assert response.status_code == 422
    assert "threshold_pct" in response.text


async def test_delete_rule(client: httpx.AsyncClient) -> None:
    headers = await _auth_headers(client, "rules-delete@example.com")
    await _add_ticker(client, headers, "NVDA")
    created = (
        await client.post(
            "/api/v1/watchlist/alerts",
            json={"ticker": "NVDA", "alert_type": "PRICE", "threshold_pct": "5.0"},
            headers=headers,
        )
    ).json()

    deleted = await client.delete(
        f"/api/v1/watchlist/alerts/{created['id']}", headers=headers
    )
    listed = await client.get("/api/v1/watchlist/alerts", headers=headers)

    assert deleted.status_code == 204
    assert listed.json() == []


async def test_rules_of_another_user_are_invisible(client: httpx.AsyncClient) -> None:
    owner = await _auth_headers(client, "rules-owner@example.com")
    intruder = await _auth_headers(client, "rules-intruder@example.com")
    await _add_ticker(client, owner, "NVDA")
    created = (
        await client.post(
            "/api/v1/watchlist/alerts",
            json={"ticker": "NVDA", "alert_type": "PRICE", "threshold_pct": "5.0"},
            headers=owner,
        )
    ).json()

    listed = await client.get("/api/v1/watchlist/alerts", headers=intruder)
    patched = await client.patch(
        f"/api/v1/watchlist/alerts/{created['id']}",
        json={"enabled": False},
        headers=intruder,
    )
    deleted = await client.delete(
        f"/api/v1/watchlist/alerts/{created['id']}", headers=intruder
    )

    assert listed.json() == []
    # 404 y no 403: distinguir "existe pero no es tuya" de "no existe" dejaría enumerar reglas
    # ajenas probando UUIDs.
    assert patched.status_code == 404
    assert deleted.status_code == 404


async def test_removing_a_ticker_removes_its_rules(
    client: httpx.AsyncClient, db_session_factory: async_sessionmaker[AsyncSession]
) -> None:
    """El CASCADE de la FK: borrar el ticker se lleva su configuración, sin dejar reglas huérfanas
    apuntando a un item que ya no existe.
    """

    headers = await _auth_headers(client, "rules-cascade@example.com")
    item = (
        await client.post(
            "/api/v1/watchlist",
            json={"ticker": "NVDA", "asset_type": "STOCK"},
            headers=headers,
        )
    ).json()
    await client.post(
        "/api/v1/watchlist/alerts",
        json={"ticker": "NVDA", "alert_type": "PRICE", "threshold_pct": "5.0"},
        headers=headers,
    )

    await client.delete(f"/api/v1/watchlist/{item['id']}", headers=headers)

    async with db_session_factory() as session:
        remaining = (await session.scalars(select(WatchlistAlertRule))).all()
    assert list(remaining) == []
