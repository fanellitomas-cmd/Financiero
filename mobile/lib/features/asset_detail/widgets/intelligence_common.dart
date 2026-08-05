import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../data/deep_intelligence.dart';

/// Piezas compartidas por las tres secciones de la Ficha de Inteligencia Profunda.

/// Banner informativo de un bloque no disponible.
///
/// La regla de la Ficha: **nunca esconder una sección ni dejarla en blanco**. Una tarjeta ausente
/// se lee como un bug; una tarjeta vacía se lee como "no hay nada que decir sobre esto", que es una
/// afirmación falsa. El banner dice qué falta y por qué, con el motivo que manda el backend.
///
/// Ámbar y no rojo a propósito: que falte una credencial no es la app rota, y pintarlo de rojo
/// haría que un entorno sin configurar pareciera roto.
class IntelligenceUnavailableBanner extends StatelessWidget {
  const IntelligenceUnavailableBanner({
    super.key,
    required this.reason,
    this.icon = Icons.info_outline,
  });

  final String? reason;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.neutral.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.neutral.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppTheme.neutral),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              reason ?? 'Este bloque no está disponible en este momento.',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Encabezado de sección con su chip de estado. El chip existe para que el usuario sepa de un
/// vistazo si lo que está leyendo está completo, sin tener que inferirlo del contenido.
class IntelligenceSectionHeader extends StatelessWidget {
  const IntelligenceSectionHeader({
    super.key,
    required this.title,
    required this.availability,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final DataAvailability availability;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null)
          trailing!
        else
          _StatusChip(availability: availability),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.availability});

  final DataAvailability availability;

  @override
  Widget build(BuildContext context) {
    // Solo se pinta cuando hay algo que advertir: un chip "AVAILABLE" en cada sección sería ruido
    // que compite con el contenido.
    if (availability == DataAvailability.available) {
      return const SizedBox.shrink();
    }

    final (label, color) = switch (availability) {
      DataAvailability.partial => ('PARCIAL', AppTheme.neutral),
      DataAvailability.unavailable => ('SIN DATOS', AppTheme.textMuted),
      DataAvailability.available => ('', AppTheme.textMuted),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: AppTheme.badgeDecoration(color),
      child: Text(
        label,
        style: AppTheme.numeric(
          fontSize: 10,
          color: color,
        ).copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// Chip de referencia a una fuente (`NEWS-1`, `SEC_10K-1`).
///
/// El backend ya descartó las refs que el modelo citó pero que no están en el corpus, así que todo
/// lo que llega acá es trazable. Se muestran en monoespaciada porque son identificadores, no prosa.
class SourceRefChip extends StatelessWidget {
  const SourceRefChip({super.key, required this.refId, this.tooltip});

  final String refId;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    // Los reportes oficiales van en cian y las noticias en gris: un 10-K tiene más peso probatorio
    // que una nota de prensa, y el color lo dice sin una leyenda aparte.
    final isFiling = refId.startsWith('SEC_') || refId.startsWith('EARNINGS');
    final color = isFiling ? AppTheme.accent : AppTheme.textMuted;

    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(refId, style: AppTheme.numeric(fontSize: 10, color: color)),
    );

    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

/// Viñeta de texto con sus refs inline al final.
///
/// Las refs van pegadas al punto que sostienen, no en una lista al pie: una viñeta con su
/// referencia al lado es verificable de un vistazo, y una lista de fuentes al final no dice qué
/// afirmación respalda cada una.
class IntelligenceBullet extends StatelessWidget {
  const IntelligenceBullet({
    super.key,
    required this.text,
    this.bulletColor,
    this.refs = const [],
  });

  final String text;
  final Color? bulletColor;
  final List<String> refs;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 8),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: bulletColor ?? AppTheme.textMuted,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: const TextStyle(fontSize: 13, height: 1.4)),
                if (refs.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    children: [
                      for (final ref in refs) SourceRefChip(refId: ref),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
