"""Formateo de la alerta final (Nodo 5, Spec.md §3.5 y §4.2). Construye el contenido semántico
una sola vez (`_build_sections`) y cada canal aplica su propia sintaxis de formato/escape —
así la lógica de traducción para principiantes vs. ficha avanzada no se duplica por canal.

Reglas de `.cursorrules`/Spec.md §4.2 aplicadas aquí:
  - Perfil `TRADUCTOR_FINANCIERO`: lidera con la consecuencia, no con el término técnico;
    semáforo en vez de probabilidad cruda; clasificación traducida a "ruido vs. señal"; nunca
    oculta incertidumbre (Spec.md §4.2 reglas 2, 3, 4, 6).
  - Perfil `FICHA_INTELIGENCIA_PROFUNDA`: probabilidades, confianza y completitud de datos
    crudas, trazables al `AssetProjection` de origen.
  - Disclaimer regulatorio en todo mensaje (Spec.md §5).
"""

from __future__ import annotations

from dataclasses import dataclass, field

from src.validation.domain_models import (
    AlertSeverity,
    AssetClass,
    AssetProjection,
    HorizonScenarios,
    MarketAlert,
    UserProfile,
    WatchedAsset,
)

_ASSET_CLASS_LABELS = {
    AssetClass.EQUITY: "📈 Acción",
    AssetClass.CRYPTO: "🪙 Criptomoneda",
}

_SEVERITY_EMOJI = {
    AlertSeverity.LOW: "🟢",
    AlertSeverity.MEDIUM: "🟡",
    AlertSeverity.HIGH: "🟠",
    AlertSeverity.CRITICAL: "🔴",
}

_HORIZON_LABELS = {
    "CORTO_1_14D": "⚡ Corto Plazo (1-14 días)",
    "MEDIANO_1_6M": "📊 Mediano Plazo (1-6 meses)",
    "LARGO_1_3A": "🏛️ Largo Plazo (1-3 años)",
}

_CLASSIFICATION_LABELS_ADVANCED = {
    "REACCION_EMOCIONAL": "Reacción Emocional del Mercado",
    "DETERIORO_FUNDAMENTAL": "Deterioro Fundamental",
    "INDETERMINADO": "Indeterminado",
}

_CLASSIFICATION_LABELS_BEGINNER = {
    "REACCION_EMOCIONAL": "Esto parece más nerviosismo del mercado que un problema real de la empresa/proyecto.",
    "DETERIORO_FUNDAMENTAL": "Esto refleja un cambio real en cómo le está yendo a la empresa/proyecto, no solo humor del mercado.",
    "INDETERMINADO": "Todavía no hay suficiente información confiable para saber si esto es ruido o algo serio.",
}

_CONFIDENCE_SEMAPHORE = {"ALTA": "🟢", "MEDIA": "🟡", "BAJA": "🟠"}

_BEGINNER_SCENARIO_PHRASES = {
    "ALCISTA": "Podría subir en este horizonte.",
    "NEUTRAL": "Podría mantenerse relativamente estable en este horizonte.",
    "BAJISTA": "Podría bajar en este horizonte.",
}

_DISCLAIMER_TEXT = (
    "Este contenido es informativo y no constituye asesoría financiera regulada."
)


@dataclass(frozen=True)
class HorizonSection:
    label: str
    body_lines: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class MessageSections:
    header: str
    classification_line: str
    horizons: list[HorizonSection]
    call_to_action: str
    disclaimer: str = _DISCLAIMER_TEXT


def _severity_emoji(alert: MarketAlert | None) -> str:
    return _SEVERITY_EMOJI[alert.severity] if alert is not None else "⚪"


def _call_to_action(*, is_beginner: bool) -> str:
    if is_beginner:
        return "Tocá para ver más detalles en la app."
    return "Ver ficha completa de inteligencia en el dashboard."


def _build_horizon_section(
    horizon: HorizonScenarios, *, is_beginner: bool
) -> HorizonSection:
    label = _HORIZON_LABELS[horizon.horizon]

    if is_beginner:
        dominant = max(horizon.scenarios, key=lambda scenario: scenario.probability_pct)
        semaphore = _CONFIDENCE_SEMAPHORE[horizon.confidence_level]
        body = [f"{semaphore} {_BEGINNER_SCENARIO_PHRASES[dominant.label]}"]
        if horizon.confidence_level == "BAJA":
            body.append(
                "Con la información disponible hasta ahora, todavía no hay certeza suficiente."
            )
        return HorizonSection(label=label, body_lines=body)

    scenario_line = ", ".join(
        f"{scenario.label} {scenario.probability_pct}%"
        for scenario in horizon.scenarios
    )
    body = [
        scenario_line,
        f"Confianza: {horizon.confidence_level} | Completitud de datos: {horizon.data_completeness_pct}%",
    ]
    return HorizonSection(label=label, body_lines=body)


def _build_sections(
    *,
    asset: WatchedAsset,
    user_profile: UserProfile,
    alert: MarketAlert | None,
    projection: AssetProjection | None,
    degraded_raw_data_only: bool,
) -> MessageSections:
    is_beginner = user_profile == UserProfile.TRADUCTOR_FINANCIERO
    asset_label = _ASSET_CLASS_LABELS[asset.asset_class]
    header = (
        f"{_severity_emoji(alert)} Alerta de Mercado — {asset_label} {asset.ticker}"
    )
    call_to_action = _call_to_action(is_beginner=is_beginner)

    if degraded_raw_data_only:
        classification_line = (
            "Detectamos un movimiento importante, pero todavía no pudimos confirmar con "
            "suficiente confianza qué lo está causando. Preferimos no arriesgar una "
            "conclusión equivocada."
            if is_beginner
            else (
                "El Guardrail marcó la interpretación generada como no verificable contra el "
                "contexto disponible (o se agotaron los reintentos permitidos). Se muestra "
                "únicamente el dato crudo detectado, sin interpretación."
            )
        )
        return MessageSections(
            header=header,
            classification_line=classification_line,
            horizons=[],
            call_to_action=call_to_action,
        )

    if projection is None:
        classification_line = (
            "Detectamos un cambio menor. No parece requerir tu atención por ahora."
            if is_beginner
            else "Variación dentro de los umbrales configurados; no se activó investigación profunda."
        )
        return MessageSections(
            header=header,
            classification_line=classification_line,
            horizons=[],
            call_to_action=call_to_action,
        )

    classification_line = (
        _CLASSIFICATION_LABELS_BEGINNER[projection.classification]
        if is_beginner
        else (
            f"Clasificación: {_CLASSIFICATION_LABELS_ADVANCED[projection.classification]} "
            f"({projection.classification_confidence_pct}% confianza)"
        )
    )
    horizons = [
        _build_horizon_section(horizon, is_beginner=is_beginner)
        for horizon in projection.horizons
    ]

    return MessageSections(
        header=header,
        classification_line=classification_line,
        horizons=horizons,
        call_to_action=call_to_action,
    )


_TELEGRAM_MARKDOWN_V2_SPECIAL_CHARS = set("_*[]()~`>#+-=|{}.!\\")


def escape_markdown_v2(text: str) -> str:
    """Escapa los caracteres especiales de Telegram MarkdownV2. Se aplica a TODO contenido
    dinámico o de texto libre — nunca a los tokens `*`/`_` que el propio template agrega para
    negrita/cursiva.
    """

    return "".join(
        f"\\{ch}" if ch in _TELEGRAM_MARKDOWN_V2_SPECIAL_CHARS else ch for ch in text
    )


_DISCORD_MARKDOWN_SPECIAL_CHARS = set("*_~`|\\")


def escape_discord_markdown(text: str) -> str:
    """Escapa los caracteres especiales del Markdown estándar de Discord (más permisivo que
    MarkdownV2 de Telegram: no requiere escapar puntuación como `.` o `!`).
    """

    return "".join(
        f"\\{ch}" if ch in _DISCORD_MARKDOWN_SPECIAL_CHARS else ch for ch in text
    )


def render_telegram_message(
    *,
    asset: WatchedAsset,
    user_profile: UserProfile,
    alert: MarketAlert | None,
    projection: AssetProjection | None,
    degraded_raw_data_only: bool,
) -> str:
    sections = _build_sections(
        asset=asset,
        user_profile=user_profile,
        alert=alert,
        projection=projection,
        degraded_raw_data_only=degraded_raw_data_only,
    )

    lines = [
        f"*{escape_markdown_v2(sections.header)}*",
        "",
        escape_markdown_v2(sections.classification_line),
    ]
    for horizon in sections.horizons:
        lines.append("")
        lines.append(f"*{escape_markdown_v2(horizon.label)}*")
        lines.extend(escape_markdown_v2(line) for line in horizon.body_lines)

    lines.append("")
    lines.append(escape_markdown_v2(sections.call_to_action))
    lines.append("")
    lines.append(f"_{escape_markdown_v2(sections.disclaimer)}_")
    return "\n".join(lines)


def render_discord_message(
    *,
    asset: WatchedAsset,
    user_profile: UserProfile,
    alert: MarketAlert | None,
    projection: AssetProjection | None,
    degraded_raw_data_only: bool,
) -> str:
    sections = _build_sections(
        asset=asset,
        user_profile=user_profile,
        alert=alert,
        projection=projection,
        degraded_raw_data_only=degraded_raw_data_only,
    )

    lines = [
        f"**{escape_discord_markdown(sections.header)}**",
        "",
        escape_discord_markdown(sections.classification_line),
    ]
    for horizon in sections.horizons:
        lines.append("")
        lines.append(f"**{escape_discord_markdown(horizon.label)}**")
        lines.extend(escape_discord_markdown(line) for line in horizon.body_lines)

    lines.append("")
    lines.append(escape_discord_markdown(sections.call_to_action))
    lines.append("")
    lines.append(f"*{escape_discord_markdown(sections.disclaimer)}*")
    return "\n".join(lines)
