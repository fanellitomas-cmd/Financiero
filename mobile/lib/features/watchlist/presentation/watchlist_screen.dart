import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/network/api_error.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/master_detail_layout.dart';
import '../../asset_detail/presentation/asset_detail_panel.dart';
import '../../asset_detail/presentation/selected_asset_controller.dart';
import '../../settings/data/exchange_type.dart';
import '../../settings/presentation/exchange_selector.dart';
import '../data/watchlist_models.dart';
import '../widgets/portfolio_audit_sheet.dart';
import 'add_ticker_dialog.dart';
import 'watchlist_alert_config_dialog.dart';
import 'watchlist_alerts_controller.dart';
import 'watchlist_controller.dart';

/// Pantalla 4: Gestión de Watchlist, filtrada por la bolsa activa (`watchlistProvider` observa
/// `selectedExchangeProvider`, así que cambiar de bolsa en el AppBar refiltra sola).
///
/// El Centro de Notificaciones es una pantalla separada (`features/alerts/`), a la que se llega
/// desde el ícono de campana del AppBar.
class WatchlistScreen extends ConsumerWidget {
  const WatchlistScreen({super.key});

  Future<void> _refreshAll(WidgetRef ref) async {
    ref.invalidate(watchlistProvider);
    ref.invalidate(fullWatchlistProvider);
    // Las reglas se refrescan con la lista: un item borrado se lleva sus reglas (CASCADE), y sin
    // esto el indicador de "2 reglas" quedaría colgado apuntando a un ticker que ya no está.
    ref.invalidate(watchlistAlertRulesProvider);
  }

  /// En escritorio abrir un activo llena el panel derecho (sin navegar, así la lista queda a la
  /// vista para saltar entre activos); en mobile no hay lugar para dos paneles, así que se
  /// navega a la ficha como pantalla completa.
  void _openAsset(BuildContext context, WidgetRef ref, WatchlistItem item) {
    if (context.isMasterDetail) {
      ref.read(selectedAssetProvider.notifier).state =
          SelectedAsset(ticker: item.ticker, assetType: item.assetType);
      return;
    }
    context.push('/asset/${item.ticker}?assetType=${item.assetType.toJson()}');
  }

  Future<void> _showEditDialog(
    BuildContext context,
    WidgetRef ref,
    WatchlistItem item,
  ) async {
    final thresholdController = TextEditingController(
      text: item.alertThresholdPct.toString(),
    );
    var enableBeginnerMode = item.enableBeginnerMode;
    String? errorText;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('Editar ${item.ticker}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: thresholdController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Umbral de alerta (%)',
                  errorText: errorText,
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Modo principiante'),
                value: enableBeginnerMode,
                onChanged: (value) =>
                    setDialogState(() => enableBeginnerMode = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () async {
                final threshold =
                    double.tryParse(thresholdController.text.trim());
                if (threshold == null || threshold <= 0 || threshold > 100) {
                  setDialogState(
                      () => errorText = 'Ingresá un número entre 0 y 100.');
                  return;
                }
                try {
                  await ref.read(watchlistRepositoryProvider).update(
                        item.id,
                        alertThresholdPct: threshold,
                        enableBeginnerMode: enableBeginnerMode,
                      );
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop(true);
                  }
                } on Object catch (error) {
                  setDialogState(() => errorText = describeApiError(error));
                }
              },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );

    if (saved ?? false) {
      await _refreshAll(ref);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watchlistAsync = ref.watch(watchlistProvider);
    final selectedExchange = ref.watch(selectedExchangeProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mi Watchlist'),
        actions: [
          // "Analizar mi Portafolio" mira la watchlist COMPLETA, no la filtrada por bolsa: una
          // auditoría de concentración que ignora la mitad de los activos porque hay un filtro de
          // NASDAQ activo mediría una cartera que el usuario no tiene. Por eso se habilita contra
          // `fullWatchlistProvider` y no contra la lista visible.
          _AuditAction(
            enabled:
                (ref.watch(fullWatchlistProvider).valueOrNull ?? []).isNotEmpty,
          ),
          // El mismo selector que el Dashboard: cambiar de bolsa acá refiltra la lista al toque.
          const ExchangeSelector(),
          IconButton(
            icon: const Icon(Icons.notifications_outlined),
            tooltip: 'Notificaciones',
            onPressed: () => context.push('/alerts'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          if (await AddTickerDialog.show(context)) {
            await _refreshAll(ref);
          }
        },
        child: const Icon(Icons.add),
      ),
      body: MasterDetailLayout(
        master: watchlistAsync.when(
          data: (items) => RefreshIndicator(
            onRefresh: () => _refreshAll(ref),
            child: items.isEmpty
                ? _EmptyState(selectedExchange: selectedExchange)
                : _WatchlistBody(
                    items: items,
                    selectedExchange: selectedExchange,
                    onOpen: (item) => _openAsset(context, ref, item),
                    onEdit: (item) => _showEditDialog(context, ref, item),
                    onConfigureAlerts: (item) async {
                      if (await WatchlistAlertConfigDialog.show(
                        context,
                        item,
                      )) {
                        // Guardar una regla de precio sincroniza el umbral del item del lado del
                        // backend, así que la lista también tiene que releerse.
                        await _refreshAll(ref);
                      }
                    },
                    onDelete: (item) async {
                      await ref
                          .read(watchlistRepositoryProvider)
                          .remove(item.id);
                      await _refreshAll(ref);
                    },
                  ),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) =>
              Center(child: Text(describeApiError(error))),
        ),
        detail: const AssetDetailPanel(),
      ),
    );
  }
}

/// Botón "Analizar mi Portafolio" del header.
///
/// Deshabilitado con la watchlist vacía, con el motivo en el tooltip: dejarlo activo abriría una
/// hoja que solo puede decir "no seguís nada", que es información que la pantalla de atrás ya está
/// mostrando.
class _AuditAction extends StatelessWidget {
  const _AuditAction({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final label = enabled
        ? 'Analizar mi Portafolio'
        : 'Agregá activos para poder analizar tu portafolio';

    // En pantalla ancha el botón va con texto: es la acción principal de la pantalla después de
    // agregar un ticker, y un ícono suelto no la comunica. En mobile no hay lugar en el AppBar
    // para dos palabras, así que queda como ícono con tooltip.
    if (context.isDesktop) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: OutlinedButton.icon(
          onPressed: enabled ? () => PortfolioAuditSheet.show(context) : null,
          icon: const Icon(Icons.donut_large, size: 16),
          label: const Text('Analizar mi Portafolio'),
        ),
      );
    }

    return IconButton(
      icon: const Icon(Icons.donut_large),
      tooltip: label,
      onPressed: enabled ? () => PortfolioAuditSheet.show(context) : null,
    );
  }
}

class _WatchlistBody extends ConsumerWidget {
  const _WatchlistBody({
    required this.items,
    required this.selectedExchange,
    required this.onOpen,
    required this.onEdit,
    required this.onConfigureAlerts,
    required this.onDelete,
  });

  final List<WatchlistItem> items;
  final ExchangeType? selectedExchange;
  final ValueChanged<WatchlistItem> onOpen;
  final ValueChanged<WatchlistItem> onEdit;
  final ValueChanged<WatchlistItem> onConfigureAlerts;
  final ValueChanged<WatchlistItem> onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hiddenCount = _hiddenCount(ref);

    return ListView.builder(
      itemCount: items.length + (hiddenCount > 0 ? 1 : 0),
      itemBuilder: (context, index) {
        if (hiddenCount > 0 && index == 0) {
          return _FilterNotice(
            selectedExchange: selectedExchange,
            hiddenCount: hiddenCount,
          );
        }
        final item = items[index - (hiddenCount > 0 ? 1 : 0)];
        final isSelected =
            ref.watch(selectedAssetProvider)?.ticker == item.ticker;
        final rules = ref.watch(tickerAlertRulesProvider(item.ticker));
        return ListTile(
          // Resaltar el seleccionado solo importa en master-detail, donde la fila y su detalle
          // conviven en pantalla; en mobile la selección es efímera (navega y vuelve).
          selected: isSelected && context.isMasterDetail,
          title: Row(
            children: [
              Text(item.ticker, style: AppTheme.tickerSymbol),
              if (rules.any((rule) => rule.enabled)) ...[
                const SizedBox(width: 8),
                _AlertRulesBadge(
                  count: rules.where((rule) => rule.enabled).length,
                ),
              ],
            ],
          ),
          subtitle: Text(_subtitleFor(item)),
          onTap: () => onOpen(item),
          // Menú y no tres íconos sueltos: con "Configurar alertas" ya son tres acciones, y tres
          // IconButton en el trailing de un ListTile no entran en el panel angosto del
          // master-detail sin comerse el subtítulo.
          trailing: PopupMenuButton<_ItemAction>(
            tooltip: 'Opciones de ${item.ticker}',
            icon: const Icon(Icons.more_vert),
            onSelected: (action) => switch (action) {
              _ItemAction.edit => onEdit(item),
              _ItemAction.alerts => onConfigureAlerts(item),
              _ItemAction.delete => onDelete(item),
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _ItemAction.edit,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(Icons.edit_outlined, size: 18),
                  title: Text('Editar'),
                ),
              ),
              PopupMenuItem(
                value: _ItemAction.alerts,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(Icons.notifications_active_outlined, size: 18),
                  title: Text('Configurar alertas'),
                ),
              ),
              PopupMenuItem(
                value: _ItemAction.delete,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(Icons.delete_outline, size: 18),
                  title: Text('Eliminar'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Cuántos items quedaron fuera por el filtro de bolsa. Se calcula contra la lista completa
  /// porque el backend filtra por igualdad estricta: con una bolsa activa también desaparecen
  /// las criptos y las acciones que todavía no están en el catálogo.
  int _hiddenCount(WidgetRef ref) {
    if (selectedExchange == null) return 0;
    final full = ref.watch(fullWatchlistProvider).valueOrNull;
    if (full == null) return 0;
    return (full.length - items.length).clamp(0, full.length);
  }

  String _subtitleFor(WatchlistItem item) {
    final kind = item.assetType == AssetType.stock ? 'Acción' : 'Cripto';
    final exchange =
        item.exchange != null ? ' · ${item.exchange!.displayName}' : '';
    final beginner = item.enableBeginnerMode ? ' · modo principiante' : '';
    return '$kind$exchange · alerta a ±${item.alertThresholdPct}%$beginner';
  }
}

enum _ItemAction { edit, alerts, delete }

/// Indicador de que el ticker tiene reglas de alerta activas.
///
/// Solo aparece cuando hay alguna: su ausencia significa "recibe todo", que es el comportamiento
/// por defecto y no necesita anunciarse en cada fila. Que aparezca es la señal de que ese ticker
/// está filtrado — información que si no, solo se ve abriendo el diálogo.
class _AlertRulesBadge extends StatelessWidget {
  const _AlertRulesBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: count == 1
          ? '1 regla de alerta activa'
          : '$count reglas de alerta activas',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: AppTheme.badgeDecoration(AppTheme.accent),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.filter_alt, size: 10, color: AppTheme.accent),
            const SizedBox(width: 3),
            Text(
              '$count',
              style: AppTheme.numeric(fontSize: 10, color: AppTheme.accent)
                  .copyWith(fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}

/// Aviso de que hay items escondidos por el filtro. Sin esto, alguien con solo cripto en la
/// watchlist vería una lista vacía al elegir NASDAQ y parecería que se le borraron los datos.
class _FilterNotice extends StatelessWidget {
  const _FilterNotice(
      {required this.selectedExchange, required this.hiddenCount});

  final ExchangeType? selectedExchange;
  final int hiddenCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.filter_alt_outlined,
              size: 18, color: AppTheme.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Mostrando solo ${selectedExchange?.displayName ?? ""}: '
              '$hiddenCount ${hiddenCount == 1 ? "activo" : "activos"} '
              '${hiddenCount == 1 ? "oculto" : "ocultos"} '
              '(cripto u otra bolsa).',
              style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends ConsumerWidget {
  const _EmptyState({required this.selectedExchange});

  final ExchangeType? selectedExchange;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final full = ref.watch(fullWatchlistProvider).valueOrNull;
    // "Vacía porque no seguís nada" y "vacía porque el filtro escondió todo" son problemas
    // distintos y el mensaje tiene que decir cuál es — si no, el filtro parece un bug.
    final hiddenByFilter =
        selectedExchange != null && full != null && full.isNotEmpty;

    return ListView(
      // ListView (no Center) para que el RefreshIndicator siga funcionando estando vacía.
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 80),
      children: [
        Icon(
          hiddenByFilter
              ? Icons.filter_alt_off_outlined
              : Icons.add_circle_outline,
          size: 40,
          color: AppTheme.textMuted,
        ),
        const SizedBox(height: 16),
        Text(
          hiddenByFilter
              ? 'Ninguno de tus ${full.length} activos cotiza en '
                  '${selectedExchange!.displayName}.\n'
                  'Cambiá de bolsa arriba para verlos.'
              : 'Agregá tu primer ticker con el botón +',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppTheme.textMuted),
        ),
      ],
    );
  }
}
