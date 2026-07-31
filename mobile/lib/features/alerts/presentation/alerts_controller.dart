import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/providers.dart';
import '../data/alert_history_models.dart';
import '../data/alerts_repository.dart';

const _pageSize = 20;

class AlertsState {
  const AlertsState({
    required this.items,
    required this.total,
    required this.isLoading,
    required this.hasMore,
    this.errorMessage,
  });

  static const initial = AlertsState(
    items: [],
    total: 0,
    isLoading: false,
    hasMore: true,
  );

  final List<AlertHistoryItem> items;
  final int total;
  final bool isLoading;
  final bool hasMore;
  final String? errorMessage;

  AlertsState copyWith({
    List<AlertHistoryItem>? items,
    int? total,
    bool? isLoading,
    bool? hasMore,
    String? errorMessage,
  }) =>
      AlertsState(
        items: items ?? this.items,
        total: total ?? this.total,
        isLoading: isLoading ?? this.isLoading,
        hasMore: hasMore ?? this.hasMore,
        errorMessage: errorMessage,
      );
}

/// Pagina `GET /api/v1/alerts` "cargar más" a "cargar más" (sin scroll infinito, más simple
/// y predecible para un boilerplate) — `loadMore()` es idempotente mientras ya haya una
/// página en vuelo o no queden más resultados.
class AlertsController extends StateNotifier<AlertsState> {
  AlertsController(this._repository) : super(AlertsState.initial) {
    loadMore();
  }

  final AlertsRepository _repository;

  Future<void> loadMore() async {
    if (state.isLoading || !state.hasMore) return;

    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final page = await _repository.list(
        limit: _pageSize,
        offset: state.items.length,
      );
      final items = [...state.items, ...page.items];
      state = state.copyWith(
        items: items,
        total: page.total,
        isLoading: false,
        hasMore: items.length < page.total,
      );
    } on Object catch (error) {
      state = state.copyWith(isLoading: false, errorMessage: describeApiError(error));
    }
  }

  Future<void> refresh() async {
    state = AlertsState.initial;
    await loadMore();
  }
}

final alertsControllerProvider =
    StateNotifierProvider.autoDispose<AlertsController, AlertsState>(
  (ref) => AlertsController(ref.watch(alertsRepositoryProvider)),
);
