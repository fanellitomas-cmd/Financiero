import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../data/corporate_models.dart';

/// Insignias y chips del Hub Corporativo.
///
/// **El color es semántica, no decoración**, y esa es la razón de que estén todas acá y no inline en
/// cada pestaña: verde y rojo en esta app significan dirección del movimiento, así que solo pueden
/// usarse para BEAT/MISS y para alcista/bajista. Una categoría de noticia pintada de verde se leería
/// como "esta noticia es buena", que es una afirmación que un heurístico de palabras clave no hace.
/// Repartir estos colores por las pestañas garantizaría que en algún lugar se rompa la regla.

/// Verde para BEAT, rojo para MISS, cian para EN LÍNEA, gris para lo que no se puede afirmar.
///
/// El cian y no el ámbar para "en línea": cumplir la estimación no es una advertencia ni un dato a
/// medias, es un resultado tan definido como los otros dos.
Color surpriseDirectionColor(SurpriseDirection direction) => switch (direction) {
      SurpriseDirection.beat => AppTheme.bullish,
      SurpriseDirection.miss => AppTheme.bearish,
      SurpriseDirection.inLine => AppTheme.accent,
      SurpriseDirection.unknown => AppTheme.textMuted,
    };

Color newsSentimentColor(NewsSentiment sentiment) => switch (sentiment) {
      NewsSentiment.bullish => AppTheme.bullish,
      NewsSentiment.bearish => AppTheme.bearish,
      NewsSentiment.neutral => AppTheme.textMuted,
    };

/// Color de una categoría de noticia, tomado de la paleta CATEGÓRICA (sin verde ni rojo) e indexado
/// por la posición del valor en su enum.
///
/// Indexar por el enum y no por la posición en la lista que se está dibujando es lo que hace que
/// RUMOR sea siempre del mismo color: si se indexara por la lista visible, filtrar el feed le
/// cambiaría el color a las categorías que quedan.
Color newsCategoryColor(NewsCategory category) =>
    AppTheme.categorical(category.index);

/// Ícono de la categoría. Acompaña al color porque el color solo no alcanza: un daltónico tiene que
/// poder distinguir un rumor de un hecho regulatorio, y esa es justamente la distinción que más
/// importa en este feed.
IconData newsCategoryIcon(NewsCategory category) => switch (category) {
      NewsCategory.rumor => Icons.help_outline,
      NewsCategory.corporate => Icons.business_outlined,
      NewsCategory.regulatory => Icons.gavel_outlined,
      NewsCategory.earnings => Icons.assessment_outlined,
      NewsCategory.market => Icons.public_outlined,
    };

/// Píldora de texto tintada. Es la forma base de todos los badges del Hub.
class CorporateBadge extends StatelessWidget {
  const CorporateBadge({
    super.key,
    required this.label,
    required this.color,
    this.icon,
    this.tooltip,
    this.dense = false,
  });

  final String label;
  final Color color;
  final IconData? icon;
  final String? tooltip;

  /// Versión compacta, para cuando el badge va dentro de una fila de lista y no en un encabezado.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 2 : 3,
      ),
      decoration: AppTheme.badgeDecoration(color),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: dense ? 10 : 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: AppTheme.numeric(
              fontSize: dense ? 9 : 10,
              color: color,
            ).copyWith(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );

    return tooltip == null ? badge : Tooltip(message: tooltip!, child: badge);
  }
}

/// Cuándo reporta respecto de la rueda. Siempre en cian/gris y nunca en verde o rojo: el horario de
/// un reporte no es una dirección de mercado.
class SessionBadge extends StatelessWidget {
  const SessionBadge({super.key, required this.session, this.dense = false});

  final EarningsSession session;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = session == EarningsSession.unknown
        ? AppTheme.textMuted
        : AppTheme.accent;
    return CorporateBadge(
      label: earningsSessionLabel(session),
      color: color,
      tooltip: earningsSessionTooltip(session),
      dense: dense,
    );
  }
}

/// BEAT / MISS / EN LÍNEA.
///
/// Con `unknown` no se dibuja nada: un badge "SIN DATO" en cada balance programado —que son la
/// mayoría del calendario— sería una columna de ruido gris compitiendo con los estimados, que es lo
/// que en esas filas sí se puede leer.
class SurpriseBadge extends StatelessWidget {
  const SurpriseBadge({
    super.key,
    required this.direction,
    this.surprisePct,
    this.dense = false,
  });

  final SurpriseDirection direction;

  /// Si viene, se muestra junto a la etiqueta. Puede ser `null` incluso en un BEAT confirmado: el
  /// backend omite el porcentaje cuando la base estimada es demasiado chica para que signifique algo.
  final String? surprisePct;

  final bool dense;

  @override
  Widget build(BuildContext context) {
    if (direction == SurpriseDirection.unknown) return const SizedBox.shrink();

    final color = surpriseDirectionColor(direction);
    final label = surprisePct == null
        ? surpriseDirectionLabel(direction)
        : '${surpriseDirectionLabel(direction)} $surprisePct';

    return CorporateBadge(
      label: label,
      color: color,
      icon: switch (direction) {
        SurpriseDirection.beat => Icons.trending_up,
        SurpriseDirection.miss => Icons.trending_down,
        SurpriseDirection.inLine => Icons.remove,
        SurpriseDirection.unknown => null,
      },
      dense: dense,
    );
  }
}

class NewsCategoryBadge extends StatelessWidget {
  const NewsCategoryBadge({super.key, required this.category, this.dense = false});

  final NewsCategory category;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return CorporateBadge(
      label: newsCategoryLabel(category),
      color: newsCategoryColor(category),
      icon: newsCategoryIcon(category),
      dense: dense,
      tooltip: category == NewsCategory.rumor
          // El rumor es la única categoría que necesita explicación: es la que puede hacer que
          // alguien opere sobre algo que todavía no pasó.
          ? 'Versión sin confirmar. No es un hecho informado por la empresa.'
          : null,
    );
  }
}

class NewsSentimentBadge extends StatelessWidget {
  const NewsSentimentBadge({
    super.key,
    required this.sentiment,
    required this.source,
    this.dense = false,
  });

  final NewsSentiment sentiment;

  /// De dónde salió la etiqueta. Va al tooltip: es lo que convierte "BAJISTA" en una pista en vez de
  /// un veredicto, y sin eso el badge afirmaría más de lo que el dato sostiene.
  final ClassificationSource source;

  final bool dense;

  @override
  Widget build(BuildContext context) {
    return CorporateBadge(
      label: newsSentimentLabel(sentiment),
      color: newsSentimentColor(sentiment),
      dense: dense,
      tooltip: classificationSourceCaption(source),
    );
  }
}

/// Aviso de "esto se sirvió de la caché del backend".
///
/// Se muestra porque el Hub habla con proveedores externos: saber que el calendario que estás mirando
/// puede tener hasta una hora explica por qué un balance que ya salió todavía figura como programado,
/// y sin eso la app parecería equivocada.
class CachedIndicator extends StatelessWidget {
  const CachedIndicator({super.key, required this.servedFromCache});

  final bool servedFromCache;

  @override
  Widget build(BuildContext context) {
    if (!servedFromCache) return const SizedBox.shrink();
    return const Tooltip(
      message: 'Servido de la caché del servidor. Actualizá para volver a pedirlo.',
      child: Icon(Icons.bolt_outlined, size: 14, color: AppTheme.textMuted),
    );
  }
}
