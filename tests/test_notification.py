"""Tests del Nodo 5: escape de MarkdownV2/Discord, plantillas (principiante vs. avanzado,
degradado, informativo) y el dispatcher end-to-end contra clientes de Telegram/Discord
mockeados (httpx.MockTransport, sin red real).
"""

from __future__ import annotations

from datetime import datetime, timezone
from decimal import Decimal
from uuid import uuid4

import httpx

from src.notification.discord_client import DiscordClient
from src.notification.dispatcher import ChannelNotificationDispatcher
from src.notification.message_templates import (
    escape_discord_markdown,
    escape_markdown_v2,
    render_discord_message,
    render_telegram_message,
)
from src.notification.telegram_client import TelegramClient
from src.validation.domain_models import (
    AlertSeverity,
    AlertTriggerType,
    AssetClass,
    AssetProjection,
    HorizonScenarios,
    MarketAlert,
    ScenarioOutcome,
    UserProfile,
    WatchedAsset,
)


def _make_alert() -> MarketAlert:
    return MarketAlert(
        alert_id=str(uuid4()),
        ticker="NVDA",
        asset_class=AssetClass.EQUITY,
        trigger_type=AlertTriggerType.PRICE_MOVE,
        severity=AlertSeverity.HIGH,
        detected_at=datetime.now(timezone.utc),
        trigger_value=Decimal("8.72"),
        threshold_breached=Decimal("6.0"),
        requires_deep_research=True,
    )


def _make_projection() -> AssetProjection:
    scenarios = [
        ScenarioOutcome(
            label="ALCISTA", probability_pct=Decimal(55), rationale="Momentum."
        ),
        ScenarioOutcome(
            label="NEUTRAL", probability_pct=Decimal(25), rationale="Neutral."
        ),
        ScenarioOutcome(
            label="BAJISTA", probability_pct=Decimal(20), rationale="Riesgo."
        ),
    ]
    return AssetProjection(
        ticker="NVDA",
        generated_at=datetime.now(timezone.utc),
        source_alert_id=str(uuid4()),
        horizons=[
            HorizonScenarios(
                horizon="CORTO_1_14D",
                scenarios=scenarios,
                confidence_level="MEDIA",
                data_completeness_pct=Decimal(60),
            ),
            HorizonScenarios(
                horizon="LARGO_1_3A",
                scenarios=scenarios,
                confidence_level="BAJA",
                data_completeness_pct=Decimal(20),
            ),
        ],
        classification="REACCION_EMOCIONAL",
        classification_confidence_pct=Decimal(65),
    )


def test_escape_markdown_v2_escapes_all_special_chars() -> None:
    raw = "NVDA -8.72% (P/E=28.5) [ok]! {test} > * _ ~ ` # + = | \\"
    escaped = escape_markdown_v2(raw)

    for char in "_*[]()~`>#+-=|{}.!\\":
        assert f"\\{char}" in escaped
    # el texto alfanumérico no debe alterarse
    assert "NVDA" in escaped
    assert "8" in escaped and "72" in escaped


def test_escape_discord_markdown_only_escapes_its_own_special_set() -> None:
    raw = "8.72% (P/E) *bold* _italic_ ~strike~ `code` | pipe"
    escaped = escape_discord_markdown(raw)

    assert "8.72%" in escaped, "Discord no requiere escapar puntuación como Telegram"
    assert "\\*bold\\*" in escaped
    assert "\\_italic\\_" in escaped
    assert "\\~strike\\~" in escaped
    assert "\\`code\\`" in escaped
    assert "\\|" in escaped


def test_telegram_message_advanced_profile_includes_raw_probabilities() -> None:
    text = render_telegram_message(
        asset=WatchedAsset(ticker="NVDA", asset_class=AssetClass.EQUITY),
        user_profile=UserProfile.FICHA_INTELIGENCIA_PROFUNDA,
        alert=_make_alert(),
        projection=_make_projection(),
        degraded_raw_data_only=False,
    )

    assert "NVDA" in text
    assert "55" in text and "25" in text and "20" in text
    assert "MEDIA" in text and "BAJA" in text
    # el disclaimer termina en punto; en MarkdownV2 un punto literal debe ir escapado
    assert "regulada\\." in text


def test_telegram_message_beginner_profile_uses_semaphore_not_raw_probabilities() -> (
    None
):
    text = render_telegram_message(
        asset=WatchedAsset(ticker="NVDA", asset_class=AssetClass.EQUITY),
        user_profile=UserProfile.TRADUCTOR_FINANCIERO,
        alert=_make_alert(),
        projection=_make_projection(),
        degraded_raw_data_only=False,
    )

    assert "Podría subir" in text
    assert "55" not in text, (
        "el perfil principiante no debe mostrar probabilidades crudas"
    )
    assert "nerviosismo del mercado" in text
    assert "asesoría financiera regulada" in text


def test_telegram_message_degraded_never_shows_projection_numbers() -> None:
    text = render_telegram_message(
        asset=WatchedAsset(ticker="NVDA", asset_class=AssetClass.EQUITY),
        user_profile=UserProfile.FICHA_INTELIGENCIA_PROFUNDA,
        alert=_make_alert(),
        projection=None,
        degraded_raw_data_only=True,
    )

    assert "Guardrail" in text
    assert "55" not in text
    assert "REACCION_EMOCIONAL" not in text


def test_discord_message_uses_double_asterisk_bold() -> None:
    text = render_discord_message(
        asset=WatchedAsset(ticker="NVDA", asset_class=AssetClass.EQUITY),
        user_profile=UserProfile.FICHA_INTELIGENCIA_PROFUNDA,
        alert=_make_alert(),
        projection=_make_projection(),
        degraded_raw_data_only=False,
    )

    assert text.startswith("**")
    assert (
        "8.72" not in text
    )  # el header no incluye el trigger crudo, solo el ticker/severidad


async def test_dispatcher_sends_via_telegram_and_reports_message_id() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"ok": True, "result": {"message_id": 4242}})

    telegram = TelegramClient(
        "fake-token",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(handler), base_url="https://api.telegram.org"
        ),
    )
    dispatcher = ChannelNotificationDispatcher(
        telegram_client=telegram, telegram_chat_id="123"
    )

    try:
        payload = await dispatcher.render_and_send(
            WatchedAsset(ticker="NVDA", asset_class=AssetClass.EQUITY),
            UserProfile.FICHA_INTELIGENCIA_PROFUNDA,
            _make_alert(),
            _make_projection(),
            False,
        )
        assert payload.notification_sent is True
        assert payload.message_id == "4242"
        assert payload.channel is not None and payload.channel.value == "TELEGRAM"
    finally:
        await telegram.aclose()


async def test_dispatcher_falls_back_to_discord_when_telegram_fails() -> None:
    def telegram_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, json={"ok": False, "description": "internal error"})

    def discord_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"id": "998877"})

    telegram = TelegramClient(
        "fake-token",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(telegram_handler),
            base_url="https://api.telegram.org",
        ),
        max_retry_attempts=1,
    )
    discord = DiscordClient(
        "https://discord.com/api/webhooks/1/token",
        http_client=httpx.AsyncClient(transport=httpx.MockTransport(discord_handler)),
    )
    dispatcher = ChannelNotificationDispatcher(
        telegram_client=telegram, telegram_chat_id="123", discord_client=discord
    )

    try:
        payload = await dispatcher.render_and_send(
            WatchedAsset(ticker="NVDA", asset_class=AssetClass.EQUITY),
            UserProfile.FICHA_INTELIGENCIA_PROFUNDA,
            _make_alert(),
            _make_projection(),
            False,
        )
        assert payload.notification_sent is True
        assert payload.message_id == "998877"
        assert payload.channel is not None and payload.channel.value == "DISCORD"
    finally:
        await telegram.aclose()
        await discord.aclose()


async def test_dispatcher_reports_not_sent_when_all_channels_fail() -> None:
    def failing_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(503, json={"error": "unavailable"})

    telegram = TelegramClient(
        "fake-token",
        http_client=httpx.AsyncClient(
            transport=httpx.MockTransport(failing_handler),
            base_url="https://api.telegram.org",
        ),
        max_retry_attempts=1,
    )
    dispatcher = ChannelNotificationDispatcher(
        telegram_client=telegram, telegram_chat_id="123"
    )

    try:
        payload = await dispatcher.render_and_send(
            WatchedAsset(ticker="NVDA", asset_class=AssetClass.EQUITY),
            UserProfile.FICHA_INTELIGENCIA_PROFUNDA,
            _make_alert(),
            _make_projection(),
            False,
        )
        assert payload.notification_sent is False
        assert payload.message_id is None
        assert payload.channel is None
    finally:
        await telegram.aclose()
