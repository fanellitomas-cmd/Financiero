import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../data/deep_intelligence.dart';

/// Ficha de Inteligencia Profunda de un ticker, family por símbolo.
///
/// `autoDispose` para que cerrar la ficha libere el análisis en vez de acumular en memoria una
/// Ficha completa por cada activo que el usuario haya mirado en la sesión. No es un problema
/// refrescar: el backend la tiene cacheada una hora, así que volver a entrar no gasta una llamada
/// al modelo.
final deepIntelligenceProvider =
    FutureProvider.autoDispose.family<DeepIntelligence, String>(
  (ref, ticker) =>
      ref.watch(deepResearchRepositoryProvider).getIntelligence(ticker),
);
