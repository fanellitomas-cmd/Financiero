import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/degradation_banner.dart';
import '../data/corporate_formatting.dart';
import '../data/corporate_models.dart';
import '../data/corporate_note_snippet.dart';
import '../presentation/corporate_controller.dart';
import 'corporate_badges.dart';
import 'earnings_history_tab.dart' show NeedsTickerPlaceholder;
import 'save_to_lab_sheet.dart';

/// Pestaña "Reportes": la biblioteca de presentaciones ante la SEC, con su síntesis opcional.
///
/// La síntesis es **opt-in y lo dice**: cuesta una llamada al modelo, y abrir la biblioteca para ver
/// qué presentó una empresa no debería gastarla. El switch está a la vista en vez de escondido en un
/// menú, porque su costo es lo que justifica que exista.
class FilingsTab extends ConsumerWidget {
  const FilingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ticker = ref.watch(corporateTickerProvider);

    if (ticker == null || ticker.isEmpty) {
      return const NeedsTickerPlaceholder(
        icon: Icons.description_outlined,
        message: 'Elegí un símbolo arriba para ver sus reportes ante la SEC '
            '(10-K anuales, 10-Q trimestrales y 8-K de hechos relevantes).',
      );
    }

    final summarize = ref.watch(filingsSummarizeProvider);
    final query = FilingsQuery(ticker: ticker, summarize: summarize);
    final filingsAsync = ref.watch(filingsProvider(query));

    return Column(
      children: [
        _FilingsToolbar(query: query),
        const Divider(height: 1, color: AppTheme.border),
        Expanded(
          child: filingsAsync.when(
            data: (response) => _FilingsBody(response: response),
            loading: () => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  if (summarize) ...[
                    const SizedBox(height: 14),
                    const Text(
                      'Generando las síntesis…',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
            error: (error, stackTrace) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(describeApiError(error), textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => ref.invalidate(filingsProvider(query)),
                      child: const Text('Reintentar'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _FilingsToolbar extends ConsumerWidget {
  const _FilingsToolbar({required this.query});

  final FilingsQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final response = ref.watch(filingsProvider(query)).valueOrNull;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              response == null
                  ? 'Reportes de ${query.ticker}'
                  : 'Reportes de ${query.ticker} · ${response.filings.length}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          // El tooltip dice el costo, que es la información que hace que la decisión de prenderlo
          // sea informada: sin eso, un switch al lado de "Síntesis IA" parece gratis.
          const Tooltip(
            message: 'Genera una síntesis por reporte. Cuesta una llamada al modelo, '
                'por eso está apagada por defecto.',
            child: Text(
              'Síntesis IA',
              style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
            ),
          ),
          Switch(
            value: query.summarize,
            onChanged: (value) =>
                ref.read(filingsSummarizeProvider.notifier).state = value,
          ),
          CachedIndicator(servedFromCache: response?.servedFromCache ?? false),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: 'Actualizar',
            onPressed: () => ref.invalidate(filingsProvider(query)),
          ),
        ],
      ),
    );
  }
}

class _FilingsBody extends StatelessWidget {
  const _FilingsBody({required this.response});

  final FilingsResponse response;

  @override
  Widget build(BuildContext context) {
    final degraded = response.availability == DataAvailability.unavailable;

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
      children: [
        if (degraded) ...[
          DegradationBanner(reason: response.degradationReason),
          const SizedBox(height: 14),
        ],
        // El motivo de la síntesis va SEPARADO del general y con su propio ícono: la lista de
        // reportes puede haber llegado perfecta y solo la síntesis haber fallado, y mezclar los dos
        // avisos haría pensar que no hay reportes.
        if (response.summaryDegradationReason != null) ...[
          DegradationBanner(
            icon: Icons.auto_awesome_outlined,
            reason: response.summaryDegradationReason,
          ),
          const SizedBox(height: 14),
        ],
        if (response.filings.isEmpty)
          _EmptyFilings(ticker: response.ticker, degraded: degraded)
        else
          for (final filing in response.filings) FilingCard(filing: filing),
      ],
    );
  }
}

/// Una presentación: tipo, fecha, enlace oficial y su síntesis desplegable.
///
/// Pública porque la Ficha del activo muestra las mismas tarjetas en su acceso rápido.
class FilingCard extends StatefulWidget {
  const FilingCard({super.key, required this.filing});

  final SecFiling filing;

  @override
  State<FilingCard> createState() => _FilingCardState();
}

class _FilingCardState extends State<FilingCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final filing = widget.filing;
    final color = switch (filing.filingType) {
      // El 10-K es el documento con más peso probatorio de los tres y va en cian, el color de acento;
      // los otros en gris. Nunca verde ni rojo: un reporte no es una dirección de mercado.
      FilingType.tenK => AppTheme.accent,
      _ => AppTheme.textMuted,
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: AppTheme.panelDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 8),
            child: Row(
              children: [
                CorporateBadge(
                  label: filing.displayType,
                  color: color,
                  icon: Icons.description_outlined,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatCorporateDate(filing.filedAt),
                        style: AppTheme.numeric(fontSize: 12.5)
                            .copyWith(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        // La descripción del tipo se muestra SIEMPRE, con o sin IA: es información
                        // estática y verdadera, y sin credenciales de modelo sigue siendo lo más
                        // útil que la pantalla puede decir del documento.
                        filingTypeDescription(filing.filingType),
                        style: const TextStyle(
                            fontSize: 10.5, color: AppTheme.textMuted),
                      ),
                    ],
                  ),
                ),
                if (filing.summaryAvailable)
                  IconButton(
                    icon: Icon(
                      _expanded ? Icons.expand_less : Icons.auto_awesome_outlined,
                      size: 18,
                      color: AppTheme.accent,
                    ),
                    tooltip: _expanded ? 'Ocultar la síntesis' : 'Ver la síntesis',
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
                _CopyLinkButton(url: filing.bestUrl),
                SaveToLabButton(
                  heading: '${filing.displayType} de ${filing.ticker} '
                      '(${formatCorporateDate(filing.filedAt)})',
                  draft: filingNoteDraft(filing),
                  snippet: buildFilingNoteMarkdown(filing),
                  ticker: filing.ticker,
                ),
              ],
            ),
          ),
          if (_expanded && filing.summary != null) _FilingSummary(summary: filing.summary!),
        ],
      ),
    );
  }
}

/// La síntesis, con su advertencia pegada.
///
/// La advertencia no es opcional ni un tooltip: la síntesis se generó sobre los METADATOS del
/// reporte (tipo y fecha), sin descargar el documento. Sin ese cartel, un párrafo bien escrito debajo
/// de "10-K" se lee como un resumen de lo que el 10-K dice.
class _FilingSummary extends StatelessWidget {
  const _FilingSummary({required this.summary});

  final String summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: const BoxDecoration(
        color: AppTheme.surfaceSunken,
        border: Border(top: BorderSide(color: AppTheme.border)),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(AppTheme.radius)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(summary, style: const TextStyle(fontSize: 12.5, height: 1.45)),
          const SizedBox(height: 10),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 13, color: AppTheme.neutral),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Generada por IA a partir del tipo y la fecha del reporte: el sistema no '
                  'descargó el documento. Es una guía de qué buscar adentro, no un resumen de lo '
                  'que dice.',
                  style: TextStyle(
                      fontSize: 10.5, color: AppTheme.textMuted, height: 1.35),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Copia el enlace oficial al portapapeles.
///
/// Se copia en vez de abrirlo: la app no tiene `url_launcher` entre sus dependencias, y agregar un
/// paquete (con su configuración por plataforma) para un botón sería desproporcionado. Copiar deja el
/// enlace disponible en cualquier navegador, y el mismo enlace queda escrito en la nota del Lab.
class _CopyLinkButton extends StatelessWidget {
  const _CopyLinkButton({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final target = url;
    return IconButton(
      icon: const Icon(Icons.link, size: 18),
      tooltip: target == null
          ? 'Este reporte llegó sin enlace del proveedor'
          : 'Copiar el enlace oficial',
      onPressed: target == null
          ? null
          : () async {
              await Clipboard.setData(ClipboardData(text: target));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Enlace copiado al portapapeles.')),
              );
            },
    );
  }
}

class _EmptyFilings extends StatelessWidget {
  const _EmptyFilings({required this.ticker, required this.degraded});

  final String ticker;
  final bool degraded;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      child: Column(
        children: [
          Icon(
            degraded ? Icons.cloud_off_outlined : Icons.folder_off_outlined,
            size: 34,
            color: AppTheme.textMuted,
          ),
          const SizedBox(height: 12),
          Text(
            degraded
                ? 'No se pudieron traer los reportes de $ticker en este momento.'
                : 'El proveedor no tiene reportes de $ticker.\n'
                    'Los ADR y las empresas que no cotizan en EE.UU. no presentan ante la SEC.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textMuted, height: 1.45),
          ),
        ],
      ),
    );
  }
}
