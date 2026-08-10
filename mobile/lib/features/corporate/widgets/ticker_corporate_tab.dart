import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/degradation_banner.dart';
import '../data/corporate_formatting.dart';
import '../data/corporate_models.dart';
import '../presentation/corporate_controller.dart';
import 'corporate_news_tab.dart' show CorporateNewsCard;
import 'earnings_calendar_tab.dart' show EarningsEventCard;

/// Acceso rápido a lo corporativo de UN activo, dentro de su Ficha: el próximo balance y sus últimas
/// noticias.
///
/// Es un resumen y no el Hub embebido: acá el usuario está mirando un activo, y las dos preguntas que
/// se hace en ese contexto son "¿cuándo reporta?" y "¿qué se dijo de esta empresa?". Para el
/// calendario de todo el mercado o el histórico de trimestres está el Hub, al que se llega con el
/// botón de la barra.
///
/// Las dos mitades tienen fuentes y degradaciones **independientes** y por eso cada una muestra su
/// propio aviso: sin credenciales del buscador de noticias el balance sigue apareciendo, y al revés.
class TickerCorporateTab extends ConsumerWidget {
  const TickerCorporateTab({super.key, required this.ticker});

  final String ticker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
      children: [
        _SectionHeader(
          title: 'Próximo balance',
          icon: Icons.event_outlined,
          action: _OpenHubButton(ticker: ticker),
        ),
        const SizedBox(height: 8),
        _NextEarnings(ticker: ticker),
        const SizedBox(height: 22),
        const _SectionHeader(
          title: 'Noticias y rumores',
          icon: Icons.newspaper_outlined,
        ),
        const SizedBox(height: 8),
        _TickerNews(ticker: ticker),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.icon, this.action});

  final String title;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppTheme.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        if (action != null) action!,
      ],
    );
  }
}

/// Lleva al Hub con el símbolo ya elegido: quien quiere el histórico completo desde la Ficha no
/// debería tener que buscar la empresa otra vez.
class _OpenHubButton extends ConsumerWidget {
  const _OpenHubButton({required this.ticker});

  final String ticker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return OutlinedButton.icon(
      onPressed: () {
        ref.read(corporateTickerProvider.notifier).state = ticker;
        context.go('/corporate');
      },
      icon: const Icon(Icons.open_in_new, size: 14),
      label: const Text('Ver en el Hub', style: TextStyle(fontSize: 11)),
    );
  }
}

class _NextEarnings extends ConsumerWidget {
  const _NextEarnings({required this.ticker});

  final String ticker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nextAsync = ref.watch(nextEarningsProvider(ticker));

    return nextAsync.when(
      data: (event) {
        if (event == null) {
          // El rango consultado se dice explícitamente: "no hay balance" sin la ventana se leería
          // como "esta empresa no reporta", y lo que pasa es que el próximo cae más allá del rango.
          return const _QuietMessage(
            icon: Icons.event_busy_outlined,
            message: 'Sin balances programados en los próximos 90 días.',
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            EarningsEventCard(event: event, showDate: true),
            Text(
              // Cuántos días faltan, en palabras: es la lectura que el usuario hace de la fecha, y
              // hacerla acá evita que la calcule mal.
              'Reporta ${formatDaysUntil(event.eventDate)} · '
              '${earningsSessionTooltip(event.session)}',
              style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
            ),
          ],
        );
      },
      loading: () => const _QuietLoader(),
      error: (error, stackTrace) => DegradationBanner(
        icon: Icons.cloud_off_outlined,
        reason: describeApiError(error),
      ),
    );
  }
}

class _TickerNews extends ConsumerWidget {
  const _TickerNews({required this.ticker});

  final String ticker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feedAsync = ref.watch(tickerNewsProvider(ticker));

    return feedAsync.when(
      data: (feed) {
        if (feed.availability == DataAvailability.unavailable) {
          return DegradationBanner(reason: feed.degradationReason);
        }
        if (feed.items.isEmpty) {
          return _QuietMessage(
            icon: Icons.newspaper_outlined,
            message: 'Sin noticias recientes de $ticker.',
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              classificationSourceCaption(ClassificationSource.keyword),
              style: const TextStyle(
                  fontSize: 10.5, color: AppTheme.textMuted, height: 1.35),
            ),
            const SizedBox(height: 10),
            for (final item in feed.items)
              CorporateNewsCard(key: ValueKey(item.refId), item: item),
          ],
        );
      },
      loading: () => const _QuietLoader(),
      error: (error, stackTrace) => DegradationBanner(
        icon: Icons.cloud_off_outlined,
        reason: describeApiError(error),
      ),
    );
  }
}

class _QuietMessage extends StatelessWidget {
  const _QuietMessage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: AppTheme.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuietLoader extends StatelessWidget {
  const _QuietLoader();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 18),
      child: Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}
