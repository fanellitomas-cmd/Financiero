import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/providers.dart';
import '../../settings/data/exchange_type.dart';
import '../data/ticker.dart';
import '../data/ticker_repository.dart';

/// Cuánto se espera desde la última tecla antes de pegarle al backend. 300ms es el punto donde
/// escribir "NVDA" dispara una sola búsqueda en vez de cuatro, sin que se sienta lento.
const _debounce = Duration(milliseconds: 300);

@immutable
class TickerSearchState {
  const TickerSearchState({
    required this.results,
    required this.isLoading,
    this.errorMessage,
  });

  static const initial = TickerSearchState(results: [], isLoading: false);

  final List<Ticker> results;
  final bool isLoading;
  final String? errorMessage;
}

/// Búsqueda incremental contra `GET /api/v1/tickers?q=...`, con debounce y descarte de
/// respuestas viejas.
///
/// El descarte importa tanto como el debounce: sin él, una respuesta lenta de "NV" que llega
/// después de la de "NVDA" sobreescribiría los resultados correctos con los anteriores (una
/// race muy visible al escribir rápido). Se resuelve con un token por búsqueda — solo la
/// última en salir tiene derecho a escribir el estado — y cancelando el request en vuelo.
class TickerSearchController extends StateNotifier<TickerSearchState> {
  TickerSearchController(this._repository) : super(TickerSearchState.initial);

  final TickerRepository _repository;

  Timer? _debounceTimer;
  CancelToken? _inFlight;
  int _latestRequestId = 0;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _inFlight?.cancel();
    super.dispose();
  }

  /// `exchange` llega por parámetro (no leído de un provider acá dentro) para que la búsqueda
  /// no quede acoplada al estado global: el diálogo decide si filtra por la bolsa activa.
  void onQueryChanged(String rawQuery, {ExchangeType? exchange}) {
    _debounceTimer?.cancel();
    final query = rawQuery.trim();

    if (query.isEmpty) {
      // Vaciar el campo cancela lo que esté en vuelo y limpia: no tiene sentido buscar "" ni
      // dejar visibles los resultados de lo que el usuario acaba de borrar.
      _inFlight?.cancel();
      _latestRequestId++;
      state = TickerSearchState.initial;
      return;
    }

    state = TickerSearchState(results: state.results, isLoading: true);
    _debounceTimer = Timer(_debounce, () => _run(query, exchange));
  }

  Future<void> _run(String query, ExchangeType? exchange) async {
    _inFlight?.cancel();
    final cancelToken = CancelToken();
    _inFlight = cancelToken;
    final requestId = ++_latestRequestId;

    try {
      final page = await _repository.search(
        query: query,
        exchange: exchange,
        cancelToken: cancelToken,
      );
      if (requestId != _latestRequestId || !mounted) return;
      state = TickerSearchState(results: page.items, isLoading: false);
    } on Object catch (error) {
      // Una cancelación no es un error que mostrarle al usuario: es el resultado esperado de
      // haber seguido escribiendo.
      if (error is DioException && CancelToken.isCancel(error)) return;
      if (requestId != _latestRequestId || !mounted) return;
      state = TickerSearchState(
        results: const [],
        isLoading: false,
        errorMessage: describeApiError(error),
      );
    }
  }
}

final tickerSearchControllerProvider = StateNotifierProvider.autoDispose<
    TickerSearchController, TickerSearchState>(
  (ref) => TickerSearchController(ref.watch(tickerRepositoryProvider)),
);
