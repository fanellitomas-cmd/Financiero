import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../data/deep_intelligence.dart';
import '../presentation/deep_intelligence_controller.dart';
import 'fundamentals_section.dart';
import 'intelligence_common.dart';
import 'projections_section.dart';
import 'rag_summary_section.dart';

/// Ficha de Inteligencia Profunda: fundamentales, síntesis de reportes y proyecciones por horizonte.
///
/// Vive en su propia pestaña del detalle del activo y NO anidada dentro del cuerpo que depende del
/// `PushNotificationPayload`: las dos Fichas tienen fuentes de datos independientes
/// (`/tickers/{ticker}/intelligence` contra `/assets/{ticker}`), y anidarla haría que un motor de
/// alertas sin credenciales dejara la Inteligencia Profunda inalcanzable aunque su propio endpoint
/// esté respondiendo bien.
///
/// El endpoint siempre devuelve 200 con estructura válida, así que el camino de `error` de acá es
/// para fallos de red o de sesión, no para "no hay datos" — eso llega como `availability` por bloque
/// y lo maneja cada sección con su banner.
class DeepIntelligenceSheet extends ConsumerWidget {
  const DeepIntelligenceSheet({super.key, required this.ticker});

  final String ticker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(deepIntelligenceProvider(ticker));

    return async.when(
      data: (intelligence) => _SheetBody(
        intelligence: intelligence,
        onRefresh: () async => ref.invalidate(deepIntelligenceProvider(ticker)),
      ),
      loading: () => const _SheetLoading(),
      error: (error, stackTrace) => _SheetError(
        message: describeApiError(error),
        onRetry: () => ref.invalidate(deepIntelligenceProvider(ticker)),
      ),
    );
  }
}

class _SheetLoading extends StatelessWidget {
  const _SheetLoading();

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
              // Se avisa que puede tardar: la primera compilación cruza cuatro proveedores más una
              // llamada al modelo, y un spinner mudo de varios segundos parece que se colgó.
              'Compilando la Ficha de Inteligencia Profunda…\n'
              'La primera vez puede tardar unos segundos.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textMuted,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetError extends StatelessWidget {
  const _SheetError({required this.message, required this.onRetry});

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

class _SheetBody extends StatelessWidget {
  const _SheetBody({required this.intelligence, required this.onRefresh});

  final DeepIntelligence intelligence;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SheetHeader(intelligence: intelligence),
          const SizedBox(height: 14),
          FundamentalsSection(fundamentals: intelligence.fundamentals),
          const SizedBox(height: 14),
          RagSummarySection(summary: intelligence.ragSummary),
          const SizedBox(height: 18),
          ProjectionsSection(projections: intelligence.projections),
          const SizedBox(height: 18),
          const _Disclaimer(),
        ],
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.intelligence});

  final DeepIntelligence intelligence;

  @override
  Widget build(BuildContext context) {
    final name = intelligence.companyName;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    intelligence.ticker,
                    style: AppTheme.tickerSymbol.copyWith(fontSize: 18),
                  ),
                  if (name != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      name,
                      style: const TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (intelligence.servedFromCache)
              Tooltip(
                // El backend cachea una hora. Decirlo evita que el usuario interprete un dato
                // estable como un dato congelado por un bug.
                message:
                    'Servida desde la caché del backend. Desplazá hacia abajo para recompilarla.',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.cached,
                      size: 13,
                      color: AppTheme.textMuted,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'en caché',
                      style: AppTheme.numeric(
                        fontSize: 10,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        // El aviso de Ficha parcial va UNA vez arriba, además del banner de cada bloque: el usuario
        // que arranca a leer sabe desde el principio que falta algo, sin tener que scrollear hasta
        // encontrarse el hueco.
        if (!intelligence.isFullyAvailable) ...[
          const SizedBox(height: 12),
          const IntelligenceUnavailableBanner(
            reason:
                'Esta Ficha está incompleta: algún bloque no pudo generarse. Cada sección '
                'indica abajo qué le falta y por qué.',
          ),
        ],
      ],
    );
  }
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'Análisis generado automáticamente sobre reportes públicos y datos de mercado. '
      'No es asesoramiento financiero ni una recomendación de compra o venta.',
      textAlign: TextAlign.center,
      style: TextStyle(color: AppTheme.textMuted, fontSize: 11, height: 1.4),
    );
  }
}
