import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/preferences_storage.dart';
import '../data/exchange_type.dart';

@immutable
class ExchangePreferenceState {
  const ExchangePreferenceState(
      {required this.selected, required this.isLoading});

  static const initial =
      ExchangePreferenceState(selected: null, isLoading: true);

  final ExchangeType? selected;
  final bool isLoading;

  /// `true` solo cuando ya terminamos de leer disco y no había nada guardado — el momento
  /// exacto para mostrar el onboarding. Mientras `isLoading` es `true` no se sabe todavía,
  /// y mostrar el diálogo ahí lo haría aparecer un instante en cada arranque.
  bool get needsOnboarding => !isLoading && selected == null;

  ExchangePreferenceState copyWith({ExchangeType? selected, bool? isLoading}) =>
      ExchangePreferenceState(
        selected: selected ?? this.selected,
        isLoading: isLoading ?? this.isLoading,
      );
}

/// Fuente de verdad de la bolsa elegida. Se carga una vez desde `PreferencesStorage` al
/// construirse y se persiste en cada cambio, así la elección sobrevive reinicios de la app.
class ExchangeController extends StateNotifier<ExchangePreferenceState> {
  ExchangeController(this._storage) : super(ExchangePreferenceState.initial) {
    _load();
  }

  final PreferencesStorage _storage;

  Future<void> _load() async {
    try {
      final stored = await _storage.readSelectedExchange();
      state = ExchangePreferenceState(
        selected: exchangeTypeFromWire(stored),
        isLoading: false,
      );
    } on Object catch (error) {
      // Si falla leer disco, se degrada a "sin preferencia" (se le vuelve a preguntar al
      // usuario) en vez de dejar la app colgada en isLoading para siempre.
      debugPrint('No se pudo leer la bolsa preferida: $error');
      state = const ExchangePreferenceState(selected: null, isLoading: false);
    }
  }

  Future<void> select(ExchangeType exchange) async {
    state = ExchangePreferenceState(selected: exchange, isLoading: false);
    try {
      await _storage.saveSelectedExchange(exchange.wireValue);
    } on Object catch (error) {
      // La selección ya se aplicó en memoria — si no se pudo persistir, la app sigue
      // usable en esta sesión y se vuelve a preguntar en el próximo arranque.
      debugPrint('No se pudo guardar la bolsa preferida: $error');
    }
  }
}
