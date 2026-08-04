import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_theme.dart';
import '../../asset_detail/data/push_notification_payload.dart';
import '../data/alert_history_models.dart';
import 'alerts_controller.dart';

/// Centro de Notificaciones (parte de la Pantalla 4): historial de alertas ya disparadas,
/// paginado, filtrado a la Watchlist del usuario — se llega acá desde el ícono de campana en
/// `WatchlistScreen`, no es una pestaña propia del shell.
class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(alertsControllerProvider);
    final controller = ref.read(alertsControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Notificaciones')),
      body: RefreshIndicator(
        onRefresh: controller.refresh,
        child: _buildBody(context, state, controller),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AlertsState state,
    AlertsController controller,
  ) {
    if (state.items.isEmpty && state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.items.isEmpty && state.errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(state.errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                  onPressed: controller.refresh,
                  child: const Text('Reintentar')),
            ],
          ),
        ),
      );
    }

    if (state.items.isEmpty) {
      return const Center(
          child: Text('Todavía no hay alertas para tu watchlist.'));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: state.items.length + 1,
      itemBuilder: (context, index) {
        if (index == state.items.length) {
          return _FooterLoadMore(state: state, controller: controller);
        }
        return _AlertTile(item: state.items[index]);
      },
    );
  }
}

class _FooterLoadMore extends StatelessWidget {
  const _FooterLoadMore({required this.state, required this.controller});

  final AlertsState state;
  final AlertsController controller;

  @override
  Widget build(BuildContext context) {
    if (!state.hasMore) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
          child: Text('No hay más notificaciones.',
              style: TextStyle(color: Colors.grey)),
        ),
      );
    }

    if (state.isLoading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: OutlinedButton(
          onPressed: controller.loadMore,
          child: const Text('Cargar más'),
        ),
      ),
    );
  }
}

class _AlertTile extends StatelessWidget {
  const _AlertTile({required this.item});

  final AlertHistoryItem item;

  @override
  Widget build(BuildContext context) {
    final color = switch (item.urgencyLevel) {
      AlertUrgency.low => Colors.grey,
      AlertUrgency.medium => AppTheme.neutral,
      AlertUrgency.high => AppTheme.bearish,
      AlertUrgency.critical => AppTheme.bearish,
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Text(
            item.ticker.substring(0, 1),
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
        ),
        title: Text(item.title ?? item.ticker),
        subtitle: Text(item.shortSummary ?? 'Sin resumen disponible.'),
        trailing: Text(
          DateFormat('dd/MM HH:mm').format(item.createdAt.toLocal()),
          style: const TextStyle(color: Colors.grey, fontSize: 12),
        ),
      ),
    );
  }
}
