import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../data/portfolio_audit.dart';
import '../data/watchlist_audit_repository.dart';

/// La Auditoría de Portafolio del usuario.
///
/// `StateNotifier` y no un `FutureProvider` a secas porque hay DOS formas de traerla que no son
/// intercambiables: abrir la pantalla respeta la caché del backend, y "Recalcular" la ignora y
/// gasta una llamada al modelo más una por símbolo a los proveedores. Con un `FutureProvider` el
/// recálculo tendría que pasar por `ref.invalidate`, que reejecuta el mismo GET cacheado — es
/// decir, el botón no haría nada.
///
/// Durante un recálculo el estado conserva el valor anterior (`copyWithPrevious`): la auditoría
/// vieja sigue en pantalla, atenuada, en vez de dejar un hueco de varios segundos donde había
/// contenido.
class PortfolioAuditController
    extends StateNotifier<AsyncValue<PortfolioAudit>> {
  PortfolioAuditController(this._repository)
      : super(const AsyncValue.loading()) {
    load();
  }

  final WatchlistAuditRepository _repository;

  Future<void> load({bool forceRefresh = false}) async {
    state = const AsyncValue<PortfolioAudit>.loading()
        .copyWithPrevious(state, isRefresh: true);
    state = await AsyncValue.guard(
      () => forceRefresh ? _repository.refreshAudit() : _repository.getAudit(),
    );
  }
}

/// `autoDispose`: cerrar la hoja libera la auditoría en vez de dejarla en memoria. Volver a
/// abrirla es barato — el backend la tiene cacheada, y si la watchlist cambió mientras tanto, la
/// caché se invalidó sola del lado del servidor (la clave incluye la composición de la cartera).
final portfolioAuditProvider = StateNotifierProvider.autoDispose<
    PortfolioAuditController, AsyncValue<PortfolioAudit>>(
  (ref) =>
      PortfolioAuditController(ref.watch(watchlistAuditRepositoryProvider)),
);
