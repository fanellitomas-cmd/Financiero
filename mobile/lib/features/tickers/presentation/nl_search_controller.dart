import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/providers.dart';
import '../data/nl_search_result.dart';
import '../data/search_nl_repository.dart';

/// Estado de la búsqueda conversacional.
///
/// A diferencia de `TickerSearchState` (el buscador incremental del catálogo), acá NO hay debounce
/// ni búsqueda al tipear: cada consulta gasta una llamada al modelo, así que se dispara solo cuando
/// el usuario la envía. Buscar mientras escribe convertiría "tecnológicas baratas" en cuatro o
/// cinco llamadas al LLM, y las intermedias serían consultas que nadie hizo.
@immutable
class NlSearchState {
  const NlSearchState({
    required this.result,
    required this.isLoading,
    this.errorMessage,
  });

  static const initial = NlSearchState(result: null, isLoading: false);

  /// `null` mientras no se haya buscado nada. Se distingue de "buscó y no encontró" (un `result`
  /// con `results` vacío): son dos pantallas distintas — una invita a escribir, la otra explica por
  /// qué no hubo coincidencias.
  final NlSearchResult? result;
  final bool isLoading;
  final String? errorMessage;

  bool get hasSearched => result != null || errorMessage != null;
}

class NlSearchController extends StateNotifier<NlSearchState> {
  NlSearchController(this._repository) : super(NlSearchState.initial);

  final SearchNlRepository _repository;

  CancelToken? _inFlight;
  int _latestRequestId = 0;

  @override
  void dispose() {
    _inFlight?.cancel();
    super.dispose();
  }

  /// Dispara la búsqueda. El descarte de respuestas viejas importa igual que en el buscador
  /// incremental: una consulta lenta que llega después de una reformulación sobreescribiría los
  /// resultados correctos con los anteriores.
  Future<void> submit(String rawQuery) async {
    final query = rawQuery.trim();
    // El backend exige 2 caracteres mínimos (422 si no): se corta acá para no gastar un request en
    // algo que ya se sabe inválido.
    if (query.length < 2) return;

    _inFlight?.cancel();
    final cancelToken = CancelToken();
    _inFlight = cancelToken;
    final requestId = ++_latestRequestId;

    state = NlSearchState(result: state.result, isLoading: true);

    try {
      final result = await _repository.search(query, cancelToken: cancelToken);
      if (requestId != _latestRequestId || !mounted) return;
      state = NlSearchState(result: result, isLoading: false);
    } on Object catch (error) {
      // Una cancelación no es un error que mostrarle al usuario: es el resultado esperado de haber
      // reformulado la consulta.
      if (error is DioException && CancelToken.isCancel(error)) return;
      if (requestId != _latestRequestId || !mounted) return;
      state = NlSearchState(
        result: null,
        isLoading: false,
        errorMessage: describeApiError(error),
      );
    }
  }

  void clear() {
    _inFlight?.cancel();
    _latestRequestId++;
    state = NlSearchState.initial;
  }
}

/// `autoDispose`: cerrar la hoja de búsqueda descarta los resultados. Volver a abrirla con la
/// búsqueda anterior en pantalla sería confuso — y recuperarla costaría otra llamada al modelo, que
/// es justamente lo que no conviene gastar sin que el usuario lo pida.
final nlSearchControllerProvider =
    StateNotifierProvider.autoDispose<NlSearchController, NlSearchState>(
  (ref) => NlSearchController(ref.watch(searchNlRepositoryProvider)),
);
