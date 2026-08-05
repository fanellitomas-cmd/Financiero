import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../data/portfolio_audit.dart';
import '../presentation/portfolio_audit_controller.dart';
import 'audit_sections.dart';

/// Auditoría de Portafolio: cómo está repartida la watchlist, qué concentra, qué se superpone y
/// qué le falta.
///
/// Se abre como hoja modal desde la Watchlist. En pantalla ancha va como diálogo centrado y
/// acotado (una hoja de 1600px de ancho deja líneas de texto ilegibles); en mobile como bottom
/// sheet a casi pantalla completa, que es donde el usuario espera este tipo de contenido.
///
/// La regla de diseño, igual que en la Ficha de Inteligencia Profunda: **mostrar lo que hay y
/// decir qué falta**. El backend degrada cada bloque por separado, así que la hoja nunca esconde
/// una sección — muestra su banner explicando por qué está vacía.
class PortfolioAuditSheet extends ConsumerWidget {
  const PortfolioAuditSheet({super.key});

  /// Abre la auditoría. Devuelve cuando el usuario la cierra.
  static Future<void> show(BuildContext context) {
    if (context.isDesktop) {
      return showDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog(
          child: ConstrainedBox(
            // 560 de ancho: el ancho de lectura cómoda para prosa, que es lo que domina esta hoja
            // (narrativa de la IA, mensajes de advertencia, notas del veredicto).
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760),
            child: const PortfolioAuditSheet(),
          ),
        ),
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => const FractionallySizedBox(
        heightFactor: 0.92,
        child: PortfolioAuditSheet(),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auditAsync = ref.watch(portfolioAuditProvider);
    final controller = ref.read(portfolioAuditProvider.notifier);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SheetHeader(
          isRefreshing: auditAsync.isLoading,
          servedFromCache: auditAsync.valueOrNull?.servedFromCache ?? false,
          onRefresh: () => controller.load(forceRefresh: true),
        ),
        const Divider(height: 1, color: AppTheme.border),
        Expanded(
          // El error va PRIMERO: si un recálculo falla, el usuario tiene que enterarse en vez de
          // seguir mirando la auditoría vieja como si nada hubiera pasado. "Reintentar" la trae de
          // vuelta.
          //
          // Se destructura `valueOrNull` y no `value`: en Riverpod, `AsyncValue.value` **relanza**
          // el error cuando el estado es `AsyncError`, así que un patrón sobre `value` explota
          // dentro del `build` en vez de caer en la rama de error.
          child: switch (auditAsync) {
            AsyncValue(:final error?) => _AuditError(
                message: describeApiError(error),
                onRetry: controller.load,
              ),
            // Un recálculo en curso sobre datos que ya estaban: se conserva el contenido y solo se
            // atenúa. Vaciar la pantalla varios segundos porque el usuario pidió refrescar sería
            // castigarlo por interactuar.
            AsyncValue(valueOrNull: final audit?) => _AuditBody(
                audit: audit,
                isStale: auditAsync.isLoading,
              ),
            _ => const _AuditLoading(),
          },
        ),
      ],
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({
    required this.isRefreshing,
    required this.servedFromCache,
    required this.onRefresh,
  });

  final bool isRefreshing;
  final bool servedFromCache;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
      child: Row(
        children: [
          const Icon(Icons.donut_large, size: 20, color: AppTheme.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Auditoría de portafolio',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (servedFromCache)
                  const Text(
                    // Decirlo evita que un dato estable se interprete como congelado por un bug.
                    'Servida desde la caché del backend',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Recalcular la auditoría',
            onPressed: isRefreshing ? null : onRefresh,
            icon: isRefreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Cerrar',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

class _AuditLoading extends StatelessWidget {
  const _AuditLoading();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              // Se avisa que puede tardar: la auditoría cruza la watchlist contra dos proveedores
              // más una llamada al modelo, y un spinner mudo de varios segundos parece colgado.
              'Analizando tu portafolio…\n'
              'Cruzamos tus activos por sector, medimos correlaciones y armamos el resumen.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppTheme.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuditError extends StatelessWidget {
  const _AuditError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined,
                size: 36, color: AppTheme.textMuted),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textMuted),
            ),
            const SizedBox(height: 14),
            FilledButton(onPressed: onRetry, child: const Text('Reintentar')),
          ],
        ),
      ),
    );
  }
}

class _AuditBody extends StatelessWidget {
  const _AuditBody({required this.audit, required this.isStale});

  final PortfolioAudit audit;

  /// `true` mientras corre un recálculo sobre datos ya mostrados.
  final bool isStale;

  @override
  Widget build(BuildContext context) {
    if (audit.isEmpty) {
      return _EmptyPortfolio(reason: audit.degradationReason);
    }

    return AnimatedOpacity(
      opacity: isStale ? 0.45 : 1,
      duration: const Duration(milliseconds: 150),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        children: [
          _PositionCountLine(audit: audit),
          const SizedBox(height: 16),
          AiSummarySection(audit: audit),
          const SizedBox(height: 18),
          SectorAllocationSection(audit: audit),
          const SizedBox(height: 18),
          ConcentrationSection(risk: audit.riskConcentration),
          const SizedBox(height: 18),
          CorrelationSection(
            warnings: audit.correlationWarnings,
            measured: audit.correlationMeasured,
          ),
          const SizedBox(height: 18),
          SuggestionsSection(
            suggestions: audit.diversificationSuggestions,
          ),
          const SizedBox(height: 20),
          const _Disclaimer(),
        ],
      ),
    );
  }
}

/// Cantidad de activos y, sobre todo, sobre qué se calcularon los porcentajes.
///
/// La aclaración de ponderación va ACÁ ARRIBA y no al pie: es la que evita que todo lo que sigue
/// se lea como plata invertida. La watchlist no guarda cantidades ni precio de compra, así que
/// "43% en Tecnología" significa 3 de cada 7 activos seguidos — y decirlo después de que el
/// usuario ya leyó la torta llega tarde.
class _PositionCountLine extends StatelessWidget {
  const _PositionCountLine({required this.audit});

  final PortfolioAudit audit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.balance, size: 16, color: AppTheme.textMuted),
          const SizedBox(width: 8),
          Expanded(
            // `Text.rich` y no `RichText`: `RichText` NO hereda el `DefaultTextStyle` del tema, así
            // que su `fontFamily` cae en la default de Material ("Roboto") — que no está
            // bundleada y que en Web CanvasKit se intenta bajar de fonts.gstatic.com. En una red
            // restringida el texto queda invisible sin ningún error, que es exactamente lo que
            // pasó la primera vez que se dibujó esta caja.
            child: Text.rich(
              TextSpan(
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 12,
                  height: 1.4,
                ),
                children: [
                  TextSpan(
                    text: '${audit.positionCount} '
                        '${audit.positionCount == 1 ? "activo seguido" : "activos seguidos"}. ',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (audit.isEqualWeighted)
                    const TextSpan(
                      text: 'Los porcentajes son sobre la CANTIDAD de activos, '
                          'no sobre el dinero invertido: la app no guarda cuántas '
                          'unidades tenés ni a qué precio las compraste.',
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyPortfolio extends StatelessWidget {
  const _EmptyPortfolio({required this.reason});

  final String? reason;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.donut_large, size: 40, color: AppTheme.textMuted),
            const SizedBox(height: 16),
            Text(
              reason ??
                  'Todavía no seguís ningún activo. Agregá al menos dos a tu watchlist '
                      'para que la auditoría pueda medir concentración y correlaciones.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textMuted, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'Análisis automático sobre la composición de tu lista de seguimiento. No es asesoramiento '
      'financiero ni una recomendación de compra o venta.',
      textAlign: TextAlign.center,
      style: TextStyle(color: AppTheme.textMuted, fontSize: 11, height: 1.4),
    );
  }
}
