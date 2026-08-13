import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/providers.dart';
import '../data/portfolio_builder_models.dart';

/// Estado del Constructor de Portafolios: el presupuesto, las posiciones que el usuario fue armando
/// y el resultado de la última simulación.
///
/// **El borrador y el resultado viven separados a propósito.** El borrador es lo que el usuario está
/// editando; el resultado es lo que el backend calculó la última vez que se le pidió. Mezclarlos
/// haría que mover un slider mostrara números "calculados" que nadie calculó todavía — y en una
/// pantalla que reparte dinero eso es exactamente la clase de afirmación que no se puede hacer.
///
/// Es un `StateNotifier` y no un `FutureProvider` sobre el borrador por lo mismo: cada tecleo en un
/// monto dispararía una simulación, con el costo de proveedor que eso implica y con resultados que se
/// pisan entre sí.

/// Presupuesto máximo aceptado por el backend (`MAX_BUDGET_USD`). Se replica acá para poder avisar
/// ANTES de mandar, en vez de traducir un 422.
const double kMaxBudgetUsd = 1000000000.0;

/// Tope de posiciones (`MAX_PORTFOLIO_ITEMS`). Mismo motivo.
const int kMaxPortfolioItems = 30;

const double kDefaultBudget = 10000;

/// Valor inicial de una posición recién agregada, por tipo de asignación.
///
/// Arranca en un número usable y no en cero: una posición en 0 no aporta nada a la simulación y
/// obligaría a tocar dos controles antes de ver cualquier resultado. El porcentaje arranca bajo a
/// propósito para que agregar el cuarto activo no se pase del presupuesto solo.
double defaultAllocationValue(AllocationType type) => switch (type) {
      AllocationType.units => 10,
      AllocationType.amountUsd => 1000,
      AllocationType.percentage => 10,
    };

// --- Borrador de la cartera -----------------------------------------------------------------------

@immutable
class PortfolioDraft {
  const PortfolioDraft({
    this.totalBudget = kDefaultBudget,
    this.items = const [],
  });

  final double totalBudget;
  final List<PortfolioItemInput> items;

  bool get isEmpty => items.isEmpty;
  bool get isFull => items.length >= kMaxPortfolioItems;

  /// La suma de lo pedido en porcentaje. Se calcula acá para poder avisar antes de simular: 120%
  /// repartido es un error de armado que conviene ver mientras se arma, no después.
  double get requestedPercentage => items
      .where((item) => item.allocationType == AllocationType.percentage)
      .fold(0.0, (total, item) => total + item.allocationValue);

  bool contains(String ticker) =>
      items.any((item) => item.ticker == ticker.toUpperCase());

  PortfolioDraft copyWith({double? totalBudget, List<PortfolioItemInput>? items}) =>
      PortfolioDraft(
        totalBudget: totalBudget ?? this.totalBudget,
        items: items ?? this.items,
      );

  PortfolioSimulationRequest toRequest() => PortfolioSimulationRequest(
        totalBudget: totalBudget,
        items: items,
      );
}

class PortfolioDraftController extends StateNotifier<PortfolioDraft> {
  PortfolioDraftController() : super(const PortfolioDraft());

  void setBudget(double value) {
    final clamped = value.clamp(0.01, kMaxBudgetUsd).toDouble();
    state = state.copyWith(totalBudget: clamped);
  }

  /// Agrega un símbolo. Si ya está, no hace nada: el backend deduplica igual, pero dejar que la lista
  /// muestre dos filas del mismo activo sugeriría que se pueden tener dos posiciones distintas y solo
  /// una sobreviviría a la simulación.
  void add(
    String ticker, {
    String assetType = 'STOCK',
    String? name,
    AllocationType type = AllocationType.percentage,
  }) {
    final symbol = ticker.trim().toUpperCase();
    if (symbol.isEmpty || state.contains(symbol) || state.isFull) return;

    state = state.copyWith(
      items: [
        ...state.items,
        PortfolioItemInput(
          ticker: symbol,
          assetType: assetType,
          name: name,
          allocationType: type,
          allocationValue: defaultAllocationValue(type),
        ),
      ],
    );
  }

  void remove(String ticker) => state = state.copyWith(
        items: state.items.where((item) => item.ticker != ticker).toList(),
      );

  void clear() => state = PortfolioDraft(totalBudget: state.totalBudget);

  /// Cambia el tipo de asignación y **reinicia el valor** al default del tipo nuevo.
  ///
  /// No se conserva el número: pasar de "10 unidades" a "10%" conservando el 10 cambia el significado
  /// del valor sin que el usuario lo pida, y con un precio alto ese 10 se convierte en una posición
  /// enorme que nadie eligió.
  void setType(String ticker, AllocationType type) => _update(
        ticker,
        (item) => item.allocationType == type
            ? item
            : item.copyWith(
                allocationType: type,
                allocationValue: defaultAllocationValue(type),
              ),
      );

  void setValue(String ticker, double value) => _update(
        ticker,
        (item) => item.copyWith(allocationValue: value <= 0 ? 0.01 : value),
      );

  /// Fija un precio esperado. `null` vuelve al precio de mercado.
  ///
  /// `null` y `0` son cosas distintas: `null` es "usá el mercado" y `0` sería un precio esperado de
  /// cero, que el backend rechaza. Por eso el parámetro es explícito y no un valor centinela.
  void setCustomPrice(String ticker, double? price) => _update(
        ticker,
        (item) => item.copyWith(
          customPrice: price == null || price <= 0 ? null : price,
        ),
      );

  void _update(
    String ticker,
    PortfolioItemInput Function(PortfolioItemInput item) transform,
  ) {
    state = state.copyWith(
      items: [
        for (final item in state.items)
          if (item.ticker == ticker) transform(item) else item,
      ],
    );
  }
}

final portfolioDraftProvider =
    StateNotifierProvider<PortfolioDraftController, PortfolioDraft>(
  (ref) => PortfolioDraftController(),
);

// --- Simulación -----------------------------------------------------------------------------------

@immutable
class PortfolioSimulationState {
  const PortfolioSimulationState({
    this.result,
    this.isRunning = false,
    this.errorMessage,
    this.ranRequest,
  });

  final PortfolioSimulationResult? result;
  final bool isRunning;
  final String? errorMessage;

  /// El pedido con el que se corrió el resultado que se está mostrando. Sirve para saber si lo que
  /// hay en pantalla todavía describe lo que el usuario tiene armado.
  final PortfolioSimulationRequest? ranRequest;

  bool get hasResult => result != null;

  /// El resultado quedó viejo respecto del borrador actual.
  ///
  /// Sin esto, cambiar el presupuesto y no volver a simular dejaría una torta que dice repartir US$
  /// 10.000 arriba de un campo que dice US$ 50.000, y las dos cosas se leerían como ciertas.
  bool isStale(PortfolioSimulationRequest current) =>
      hasResult && ranRequest != null && ranRequest != current;
}

class PortfolioSimulationController
    extends StateNotifier<PortfolioSimulationState> {
  PortfolioSimulationController(this._ref)
      : super(const PortfolioSimulationState());

  final Ref _ref;

  Future<void> run() async {
    final draft = _ref.read(portfolioDraftProvider);
    if (draft.isEmpty || state.isRunning) return;

    final request = draft.toRequest();
    state = PortfolioSimulationState(
      result: state.result,
      isRunning: true,
      ranRequest: state.ranRequest,
    );

    try {
      final result =
          await _ref.read(portfolioBuilderRepositoryProvider).simulate(request);
      if (!mounted) return;
      state = PortfolioSimulationState(result: result, ranRequest: request);
    } on Object catch (error) {
      if (!mounted) return;
      // Se conserva el resultado anterior: borrarlo ante un error de red dejaría la pantalla en
      // blanco y perdería un reparto que sigue siendo válido, sin ganar nada.
      state = PortfolioSimulationState(
        result: state.result,
        errorMessage: describeApiError(error),
        ranRequest: state.ranRequest,
      );
    }
  }

  void reset() => state = const PortfolioSimulationState();
}

final portfolioSimulationProvider = StateNotifierProvider<
    PortfolioSimulationController, PortfolioSimulationState>(
  (ref) => PortfolioSimulationController(ref),
);
