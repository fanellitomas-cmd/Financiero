import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/degradation_banner.dart';
import '../../watchlist/data/portfolio_audit.dart' show PortfolioSector, sectorDisplayName;
import '../data/corporate_formatting.dart';
import '../data/corporate_models.dart';
import '../data/corporate_note_snippet.dart';
import '../presentation/corporate_controller.dart';
import 'corporate_badges.dart';
import 'save_to_lab_sheet.dart';

/// Pestaña "Calendario": qué empresas reportan en la ventana elegida, agrupadas por día.
///
/// Se agrupa por día y no se muestra una lista plana con la fecha en cada fila: la pregunta que se le
/// hace a un calendario es "qué pasa el martes", y una columna de fechas repetidas obliga a
/// reconstruir esos grupos a ojo.
class EarningsCalendarTab extends ConsumerWidget {
  const EarningsCalendarTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(calendarQueryProvider);
    final calendarAsync = ref.watch(activeEarningsCalendarProvider);

    return Column(
      children: [
        const _CalendarToolbar(),
        const Divider(height: 1, color: AppTheme.border),
        Expanded(
          child: calendarAsync.when(
            data: (calendar) => _CalendarBody(calendar: calendar),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stackTrace) => _CalendarError(
              error: error,
              onRetry: () => ref.invalidate(earningsCalendarProvider(query)),
            ),
          ),
        ),
      ],
    );
  }
}

class _CalendarToolbar extends ConsumerWidget {
  const _CalendarToolbar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(calendarQueryProvider);
    final controller = ref.read(calendarQueryProvider.notifier);
    final calendar = ref.watch(activeEarningsCalendarProvider).valueOrNull;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left, size: 20),
                tooltip: 'Ventana anterior',
                onPressed: () => controller.shift(forward: false),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      // El rango que se muestra es el EFECTIVO que devolvió el backend, no el que se
                      // pidió: aplica su propio tope, y mostrar el pedido dejaría el encabezado
                      // mintiendo sobre lo que hay abajo.
                      calendar == null
                          ? '${formatCorporateDate(query.from)} — ${formatCorporateDate(query.to)}'
                          : '${formatCorporateDate(calendar.fromDate)} — '
                              '${formatCorporateDate(calendar.toDate)}',
                      style: AppTheme.numeric(fontSize: 12).copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (calendar != null)
                      Text(
                        '${calendar.total} balance${calendar.total == 1 ? "" : "s"}',
                        style: const TextStyle(
                            fontSize: 10, color: AppTheme.textMuted),
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right, size: 20),
                tooltip: 'Ventana siguiente',
                onPressed: () => controller.shift(forward: true),
              ),
              CachedIndicator(
                servedFromCache: calendar?.servedFromCache ?? false,
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Actualizar',
                onPressed: () =>
                    ref.invalidate(earningsCalendarProvider(query)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                SegmentedButton<CalendarWindow>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: [
                    for (final window in CalendarWindow.values)
                      ButtonSegment(
                        value: window,
                        label: Text(
                          calendarWindowLabel(window),
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                  ],
                  selected: {query.window},
                  onSelectionChanged: (selection) =>
                      controller.setWindow(selection.first),
                ),
                const SizedBox(width: 10),
                if (query.from != todayOnly())
                  OutlinedButton.icon(
                    onPressed: controller.reset,
                    icon: const Icon(Icons.today_outlined, size: 14),
                    label: const Text('Hoy', style: TextStyle(fontSize: 11)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const _CalendarFilters(),
        ],
      ),
    );
  }
}

/// Filtros por símbolo y por sector.
///
/// Se muestra explícitamente que **no se combinan**: el backend le da prioridad al símbolo, y dejar
/// los dos activos en la UI haría creer que se está viendo la intersección — que casi siempre es una
/// fila o ninguna, y se leería como un bug.
class _CalendarFilters extends ConsumerStatefulWidget {
  const _CalendarFilters();

  @override
  ConsumerState<_CalendarFilters> createState() => _CalendarFiltersState();
}

class _CalendarFiltersState extends ConsumerState<_CalendarFilters> {
  final _tickerController = TextEditingController();

  @override
  void dispose() {
    _tickerController.dispose();
    super.dispose();
  }

  /// Los sectores que se ofrecen. `cripto` y `sinClasificar` quedan afuera: ninguna cripto reporta
  /// balances trimestrales ante la SEC, así que filtrar por ese sector devolvería siempre vacío.
  static const _sectors = [
    PortfolioSector.tecnologia,
    PortfolioSector.salud,
    PortfolioSector.serviciosFinancieros,
    PortfolioSector.consumoDiscrecional,
    PortfolioSector.consumoBasico,
    PortfolioSector.industria,
    PortfolioSector.energia,
    PortfolioSector.materiales,
    PortfolioSector.serviciosPublicos,
    PortfolioSector.bienesRaices,
    PortfolioSector.comunicaciones,
  ];

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(calendarQueryProvider);
    final controller = ref.read(calendarQueryProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 118,
              child: TextField(
                controller: _tickerController,
                textCapitalization: TextCapitalization.characters,
                style: AppTheme.numeric(fontSize: 12),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Símbolo',
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                ),
                onSubmitted: controller.setTicker,
              ),
            ),
            const SizedBox(width: 8),
            if (query.ticker != null)
              InputChip(
                label: Text(query.ticker!, style: AppTheme.numeric(fontSize: 11)),
                onDeleted: () {
                  _tickerController.clear();
                  controller.setTicker(null);
                },
              ),
            if (query.sector != null) ...[
              const SizedBox(width: 6),
              InputChip(
                avatar: const Icon(Icons.category_outlined, size: 14),
                label: Text(query.sector!, style: const TextStyle(fontSize: 11)),
                onDeleted: () => controller.setSector(null),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final sector in _sectors)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: Text(
                      sectorDisplayName(sector),
                      style: const TextStyle(fontSize: 11),
                    ),
                    visualDensity: VisualDensity.compact,
                    selected: query.sector == sectorDisplayName(sector),
                    onSelected: (selected) {
                      // Elegir un sector borra el símbolo: son dos preguntas distintas y el backend
                      // atiende solo una. El chip del símbolo desaparece con él, así que la pantalla
                      // nunca muestra un filtro que no está filtrando.
                      _tickerController.clear();
                      controller.setSector(
                        selected ? sectorDisplayName(sector) : null,
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CalendarBody extends StatelessWidget {
  const _CalendarBody({required this.calendar});

  final EarningsCalendar calendar;

  @override
  Widget build(BuildContext context) {
    final degraded = calendar.availability == DataAvailability.unavailable;
    final grouped = calendar.eventsByDay;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        if (degraded) ...[
          DegradationBanner(reason: calendar.degradationReason),
          const SizedBox(height: 14),
        ],
        if (calendar.unclassifiedBySector > 0) ...[
          // Se dice cuántos quedaron afuera del filtro por sector: sin esto, una lista corta se lee
          // como "esta semana no reporta nadie más de este sector", y lo que pasó es que el catálogo
          // local no conoce el sector de esos símbolos.
          DegradationBanner(
            icon: Icons.filter_alt_outlined,
            reason: '${calendar.unclassifiedBySector} balance(s) quedaron afuera '
                'del filtro por sector: el catálogo local no tiene el sector de esos símbolos.',
          ),
          const SizedBox(height: 14),
        ],
        if (grouped.isEmpty)
          _EmptyCalendar(degraded: degraded)
        else
          for (final entry in grouped.entries)
            _DayGroup(day: entry.key, events: entry.value),
      ],
    );
  }
}

class _DayGroup extends StatelessWidget {
  const _DayGroup({required this.day, required this.events});

  final DateTime day;
  final List<EarningsEvent> events;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 2),
            child: Row(
              children: [
                Text(
                  formatCalendarDay(day),
                  style: AppTheme.numeric(fontSize: 12, color: AppTheme.accent)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                Text(
                  formatDaysUntil(day),
                  style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
                ),
                const SizedBox(width: 8),
                const Expanded(child: Divider(color: AppTheme.border)),
              ],
            ),
          ),
          for (final event in events) EarningsEventCard(event: event),
        ],
      ),
    );
  }
}

/// Una fila del calendario: el símbolo, cuándo reporta y qué se espera.
///
/// Reutilizada por la Ficha del activo (acceso rápido al próximo balance), así que es pública.
class EarningsEventCard extends StatelessWidget {
  const EarningsEventCard({super.key, required this.event, this.showDate = false});

  final EarningsEvent event;

  /// En el calendario la fecha ya está en el encabezado del grupo; en la Ficha, donde la tarjeta va
  /// suelta, hace falta.
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: AppTheme.panelDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(event.ticker, style: AppTheme.tickerSymbol.copyWith(fontSize: 14)),
              const SizedBox(width: 8),
              SessionBadge(session: event.session, dense: true),
              const SizedBox(width: 6),
              if (event.status == EarningsStatus.reported)
                SurpriseBadge(
                  direction: event.surpriseDirection,
                  surprisePct: event.epsSurprisePct == null
                      ? null
                      : formatSurprisePct(event.epsSurprisePct),
                  dense: true,
                ),
              const Spacer(),
              SaveToLabButton(
                heading: 'Balance de ${event.ticker} del '
                    '${formatCorporateDate(event.eventDate)}',
                draft: earningsNoteDraft(event),
                snippet: buildEarningsNoteMarkdown(event),
                ticker: event.ticker,
              ),
            ],
          ),
          if (event.companyName != null || showDate || formatFiscalPeriod(event) != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: Text(
                [
                  if (showDate) formatCorporateDate(event.eventDate),
                  if (event.companyName != null) event.companyName!,
                  if (formatFiscalPeriod(event) != null) formatFiscalPeriod(event)!,
                ].join(' · '),
                style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          _EstimateRow(event: event),
        ],
      ),
    );
  }
}

/// Estimado vs. reportado de EPS e ingresos.
///
/// Para un balance PROGRAMADO se muestra solo el estimado, y la columna "reportado" no se dibuja en
/// vez de aparecer con un `—`: una columna vacía en cada fila del calendario sugiere que falta un
/// dato que en realidad todavía no existe.
class _EstimateRow extends StatelessWidget {
  const _EstimateRow({required this.event});

  final EarningsEvent event;

  @override
  Widget build(BuildContext context) {
    final reported = event.status == EarningsStatus.reported;

    return Wrap(
      spacing: 18,
      runSpacing: 6,
      children: [
        _Metric(
          label: 'EPS est.',
          value: formatEps(event.epsEstimated),
        ),
        if (reported)
          _Metric(
            label: 'EPS rep.',
            value: formatEps(event.epsActual),
            color: surpriseDirectionColor(event.surpriseDirection),
          ),
        if (reported && event.epsSurprise != null)
          _Metric(
            label: 'Sorpresa',
            value: formatEpsDelta(event.epsSurprise),
            color: surpriseDirectionColor(event.surpriseDirection),
          ),
        if (event.revenueEstimated != null)
          _Metric(
            label: 'Ingresos est.',
            value: formatRevenue(event.revenueEstimated),
          ),
        if (reported && event.revenueActual != null)
          _Metric(
            label: 'Ingresos rep.',
            value: formatRevenue(event.revenueActual),
          ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 9.5, color: AppTheme.textMuted),
        ),
        Text(value, style: AppTheme.numeric(fontSize: 12.5, color: color)),
      ],
    );
  }
}

class _EmptyCalendar extends StatelessWidget {
  const _EmptyCalendar({required this.degraded});

  final bool degraded;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Column(
        children: [
          Icon(
            degraded ? Icons.cloud_off_outlined : Icons.event_available_outlined,
            size: 36,
            color: AppTheme.textMuted,
          ),
          const SizedBox(height: 12),
          Text(
            // Los dos vacíos posibles se dicen distinto, que es toda la razón por la que el backend
            // manda `availability`: uno se arregla esperando, el otro no se arregla mirando la app.
            degraded
                ? 'No se pudo traer el calendario en este momento. El aviso de arriba dice por qué.'
                : 'Ningún balance programado en esta ventana.\n'
                    'Probá con un rango más largo o quitá los filtros.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textMuted, height: 1.45),
          ),
        ],
      ),
    );
  }
}

class _CalendarError extends StatelessWidget {
  const _CalendarError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(describeApiError(error), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Reintentar')),
          ],
        ),
      ),
    );
  }
}
