import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/providers.dart';
import '../data/ai_lab_models.dart';

/// Estado del Laboratorio Financiero: qué símbolo se está analizando, el hilo de la conversación
/// contable y el resultado de la última simulación.
///
/// Las dos vistas usan `StateNotifier` y no `FutureProvider` por la misma razón, aunque por caminos
/// distintos:
///
///   - El **diagnóstico** es una conversación: cada pregunta manda el historial que el backend
///     devolvió en el turno anterior. Un `FutureProvider` reconstruiría el request desde cero en cada
///     invalidación y perdería el hilo.
///   - La **simulación** se dispara con un botón y cuesta una llamada al modelo. Con un
///     `FutureProvider` sobre las variables, mover un slider lanzaría una simulación por frame.

// --- Símbolo y periodicidad ----------------------------------------------------------------------

/// El símbolo que mira todo el Laboratorio.
///
/// Es compartido por las dos pestañas: quien acaba de ver que una empresa tiene deuda alta y pasa al
/// simulador para subirle la tasa está siguiendo la misma pregunta sobre la misma empresa, y hacerle
/// elegir el símbolo dos veces rompe ese hilo.
final aiLabTickerProvider = StateProvider<String?>((ref) => null);

/// Anual o trimestral. También compartida: comparar un diagnóstico anual con una simulación
/// trimestral daría dos lecturas que no se pueden cruzar.
final aiLabPeriodProvider =
    StateProvider<StatementPeriod>((ref) => StatementPeriod.annual);

// --- Diagnóstico contable ------------------------------------------------------------------------

/// Estado del diagnóstico y su hilo.
@immutable
class AnalysisState {
  const AnalysisState({
    this.ticker,
    this.analysis,
    this.isLoading = false,
    this.isAsking = false,
    this.errorMessage,
  });

  final String? ticker;

  /// La última respuesta del backend. Su `history` es el hilo completo y es lo que se manda en el
  /// próximo turno.
  final FinancialAnalysisResponse? analysis;

  /// Cargando el diagnóstico inicial: la pantalla no tiene nada que mostrar todavía.
  final bool isLoading;

  /// Esperando la respuesta a una pregunta. Se distingue de [isLoading] porque el diagnóstico YA está
  /// en pantalla y reemplazarlo por un spinner haría desaparecer lo que el usuario está leyendo
  /// mientras espera.
  final bool isAsking;

  final String? errorMessage;

  List<ConversationTurn> get history => analysis?.history ?? const [];

  bool get hasData => analysis != null;

  bool get isBusy => isLoading || isAsking;

  AnalysisState copyWith({
    bool clearTicker = false,
    String? ticker,
    bool clearAnalysis = false,
    FinancialAnalysisResponse? analysis,
    bool? isLoading,
    bool? isAsking,
    bool clearError = false,
    String? errorMessage,
  }) =>
      AnalysisState(
        ticker: clearTicker ? null : (ticker ?? this.ticker),
        analysis: clearAnalysis ? null : (analysis ?? this.analysis),
        isLoading: isLoading ?? this.isLoading,
        isAsking: isAsking ?? this.isAsking,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      );
}

class AnalysisController extends StateNotifier<AnalysisState> {
  AnalysisController(this._ref) : super(const AnalysisState());

  final Ref _ref;

  /// Carga el diagnóstico general del símbolo, sin pregunta.
  ///
  /// Reinicia el hilo: el historial es de una conversación sobre UNA empresa, y arrastrar las
  /// preguntas de otra haría que el modelo responda sobre estados contables que ya no están en el
  /// contexto.
  Future<void> load(String ticker, {bool force = false}) async {
    final normalized = ticker.trim().toUpperCase();
    if (normalized.isEmpty) return;
    if (!force && state.ticker == normalized && state.hasData) return;

    state = AnalysisState(ticker: normalized, isLoading: true);

    try {
      final analysis = await _ref.read(aiLabRepositoryProvider).analyze(
            ticker: normalized,
            period: _ref.read(aiLabPeriodProvider),
          );
      if (!mounted) return;
      state = AnalysisState(ticker: normalized, analysis: analysis);
    } on Object catch (error) {
      if (!mounted) return;
      state = AnalysisState(
        ticker: normalized,
        errorMessage: _describe(error),
      );
    }
  }

  /// Manda una pregunta con el hilo que el backend devolvió.
  Future<void> ask(String question) async {
    final ticker = state.ticker;
    final trimmed = question.trim();
    if (ticker == null || trimmed.isEmpty || state.isBusy) return;

    state = state.copyWith(isAsking: true, clearError: true);

    try {
      final analysis = await _ref.read(aiLabRepositoryProvider).analyze(
            ticker: ticker,
            period: _ref.read(aiLabPeriodProvider),
            question: trimmed,
            // El historial que viaja es el que el backend armó, no uno que compongamos acá: así el
            // servidor ve exactamente el hilo que él mismo cerró en el turno anterior.
            history: state.history,
          );
      if (!mounted) return;
      state = state.copyWith(analysis: analysis, isAsking: false);
    } on Object catch (error) {
      if (!mounted) return;
      // El diagnóstico se conserva: la pregunta falló, pero lo que estaba en pantalla sigue siendo
      // válido y borrarlo castigaría al usuario por un error de red.
      state = state.copyWith(isAsking: false, errorMessage: _describe(error));
    }
  }

  /// Vacía el hilo sin volver a pedir el diagnóstico.
  ///
  /// Existe porque el historial se manda en cada request y crece: cuando la conversación se fue por
  /// las ramas, empezar de nuevo es más barato que arrastrar veinte turnos que ya no importan.
  void clearConversation() {
    final analysis = state.analysis;
    if (analysis == null) return;
    state = state.copyWith(
      analysis: FinancialAnalysisResponse(
        ticker: analysis.ticker,
        companyName: analysis.companyName,
        period: analysis.period,
        generatedAt: analysis.generatedAt,
        incomeStatements: analysis.incomeStatements,
        balanceSheets: analysis.balanceSheets,
        cashFlows: analysis.cashFlows,
        dupont: analysis.dupont,
        flags: analysis.flags,
        narrative: analysis.narrative,
        narrativeSource: analysis.narrativeSource,
        history: const [],
        availability: analysis.availability,
        degradationReason: analysis.degradationReason,
        narrativeDegradationReason: analysis.narrativeDegradationReason,
        servedFromCache: analysis.servedFromCache,
      ),
      clearError: true,
    );
  }

  void reset() => state = const AnalysisState();

  String _describe(Object error) => describeAiLabError(error);
}

final analysisControllerProvider =
    StateNotifierProvider<AnalysisController, AnalysisState>(
  (ref) => AnalysisController(ref),
);

// --- Simulador -----------------------------------------------------------------------------------

/// Las variables que el usuario tiene puestas ahora.
///
/// Arrancan TODAS sin fijar y eso no es un detalle: en dos de las cuatro palancas, "sin fijar" y "en
/// cero" son escenarios distintos (un margen sin fijar deja que la inflación lo mueva; una tasa sin
/// fijar mantiene el gasto de intereses del balance). Arrancar con valores por defecto convertiría
/// supuestos nuestros en supuestos del usuario.
class ScenarioVariablesController extends StateNotifier<ScenarioVariables> {
  ScenarioVariablesController() : super(const ScenarioVariables());

  /// Valores con los que se activa cada palanca. Son un punto de partida visible y editable, no un
  /// supuesto escondido: el usuario ve el número en el slider desde el momento en que lo activa.
  static const double defaultGrowthPct = 10;
  static const double defaultMarginPct = 30;
  static const double defaultInterestPct = 8;
  static const double defaultInflationPct = 5;

  void setGrowth(double? value) => state = value == null
      ? state.copyWith(clearGrowth: true)
      : state.copyWith(revenueGrowthPct: value);

  void setMargin(double? value) => state = value == null
      ? state.copyWith(clearMargin: true)
      : state.copyWith(ebitdaMarginPct: value);

  void setInterest(double? value) => state = value == null
      ? state.copyWith(clearInterest: true)
      : state.copyWith(interestRatePct: value);

  void setInflation(double? value) => state = value == null
      ? state.copyWith(clearInflation: true)
      : state.copyWith(inflationPct: value);

  void setCustomEvent(String? value) {
    final trimmed = value?.trim();
    state = (trimmed == null || trimmed.isEmpty)
        ? state.copyWith(clearEvent: true)
        : state.copyWith(customEvent: trimmed);
  }

  /// Activa el margen partiendo del margen REAL de la empresa cuando se lo conoce.
  ///
  /// Arrancar en el margen del balance y no en un 30% genérico hace que el primer movimiento del
  /// slider sea una decisión sobre el negocio de esa empresa y no sobre un número inventado.
  void activateMargin({double? baselineMarginPct}) {
    final start = baselineMarginPct ?? defaultMarginPct;
    setMargin(start.clamp(-100.0, 100.0));
  }

  /// Ídem con la tasa: se parte de la tasa implícita del balance si el backend la pudo deducir.
  void activateInterest({double? impliedRatePct}) {
    final start = impliedRatePct ?? defaultInterestPct;
    setInterest(start.clamp(0.0, 100.0));
  }

  void reset() => state = const ScenarioVariables();
}

final scenarioVariablesProvider =
    StateNotifierProvider<ScenarioVariablesController, ScenarioVariables>(
  (ref) => ScenarioVariablesController(),
);

/// Estado de la simulación.
@immutable
class SimulationState {
  const SimulationState({
    this.result,
    this.isRunning = false,
    this.errorMessage,
    this.ranVariables,
  });

  final ScenarioSimulationResult? result;
  final bool isRunning;
  final String? errorMessage;

  /// Con qué variables se corrió el resultado que está en pantalla. Se compara con las actuales para
  /// poder avisar que lo que se ve no corresponde a lo que los sliders muestran ahora — sin eso, mover
  /// un slider y leer el resultado viejo es el error más fácil de cometer en esta pantalla.
  final ScenarioVariables? ranVariables;

  bool get hasResult => result != null;

  bool isStale(ScenarioVariables current) =>
      ranVariables != null && ranVariables != current;
}

class SimulationController extends StateNotifier<SimulationState> {
  SimulationController(this._ref) : super(const SimulationState());

  final Ref _ref;

  Future<void> run() async {
    final ticker = _ref.read(aiLabTickerProvider);
    if (ticker == null || ticker.isEmpty || state.isRunning) return;

    final variables = _ref.read(scenarioVariablesProvider);
    state = SimulationState(
      result: state.result,
      isRunning: true,
      ranVariables: state.ranVariables,
    );

    try {
      final result = await _ref.read(aiLabRepositoryProvider).simulate(
            ticker: ticker,
            period: _ref.read(aiLabPeriodProvider),
            variables: variables,
          );
      if (!mounted) return;
      state = SimulationState(result: result, ranVariables: variables);
    } on Object catch (error) {
      if (!mounted) return;
      state = SimulationState(
        result: state.result,
        errorMessage: describeAiLabError(error),
        ranVariables: state.ranVariables,
      );
    }
  }

  void reset() => state = const SimulationState();
}

final simulationControllerProvider =
    StateNotifierProvider<SimulationController, SimulationState>(
  (ref) => SimulationController(ref),
);

/// Traduce un error de transporte a algo que el usuario pueda leer.
///
/// Envuelve a `describeApiError` en vez de llamarlo directo desde cada controller para que las dos
/// vistas digan lo mismo ante el mismo problema: dos mensajes distintos para un timeout harían pensar
/// que son dos fallas.
String describeAiLabError(Object error) => describeApiError(error);
