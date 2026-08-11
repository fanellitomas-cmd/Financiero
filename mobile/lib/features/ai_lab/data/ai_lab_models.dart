/// Modelos de `/api/v1/ai-lab/*` — el Laboratorio Financiero y el Simulador de Escenarios.
///
/// Espejan `app/schemas/ai_lab.py`. Cuatro reglas del contrato que este archivo tiene que preservar
/// tal cual, porque son las que evitan que la UI afirme cosas que nadie calculó:
///
///   1. **Ningún número de la respuesta lo escribió el modelo.** Márgenes, DuPont, banderas,
///      proyección y precio implícito salen de fórmulas en el backend; la prosa es lo único que
///      redacta la IA, y [FinancialAnalysisResponse.narrativeSource] lo declara.
///   2. **`null` no es `0`.** Un margen que no se pudo calcular, un precio implícito sin múltiplo que
///      sostener y un EPS ausente viajan en `null`. Pintarlos como cero afirmaría "reportó
///      exactamente cero", que es otra cosa.
///   3. **Las variaciones se miden contra el punto cero del MODELO** ([ScenarioBaseline.modelEps]),
///      no contra el EPS reportado. Los dos viajan y son distintos a propósito.
///   4. **El evento en texto no mueve ningún número** y la respuesta lo dice con
///      [ScenarioSimulationResult.customEventIsQualitative].
///
/// Mismo criterio de parseo que el resto de la app: todo enum se parsea con fallback, nunca con
/// `throw`. Un valor nuevo del backend degrada ese campo, no tira la pantalla.
library;

import 'package:flutter/foundation.dart';

import '../../../core/data/data_availability.dart';

export '../../../core/data/data_availability.dart'
    show DataAvailability, availabilityFromWire;

// --- Vocabulario ---------------------------------------------------------------------------------

/// Periodicidad de los estados contables. Viaja en el pedido y en la respuesta: un margen trimestral
/// y uno anual no se comparan entre sí, y una pantalla sin decir cuál mira invita a esa comparación.
enum StatementPeriod { annual, quarter }

StatementPeriod statementPeriodFromWire(String? value) =>
    value == 'QUARTER' ? StatementPeriod.quarter : StatementPeriod.annual;

String statementPeriodToWire(StatementPeriod period) =>
    period == StatementPeriod.quarter ? 'QUARTER' : 'ANNUAL';

String statementPeriodLabel(StatementPeriod period) =>
    period == StatementPeriod.quarter ? 'Trimestral' : 'Anual';

/// Si la bandera es un riesgo o una fortaleza.
enum FlagKind { red, green }

/// `red` como fallback: ante un valor desconocido, la lectura prudente no es "esto es una fortaleza".
FlagKind flagKindFromWire(String? value) =>
    value == 'GREEN' ? FlagKind.green : FlagKind.red;

enum FlagSeverity { info, warning, critical }

FlagSeverity flagSeverityFromWire(String? value) => switch (value) {
      'CRITICAL' => FlagSeverity.critical,
      'WARNING' => FlagSeverity.warning,
      _ => FlagSeverity.info,
    };

String flagSeverityLabel(FlagSeverity severity) => switch (severity) {
      FlagSeverity.critical => 'CRÍTICO',
      FlagSeverity.warning => 'ATENCIÓN',
      FlagSeverity.info => 'DATO',
    };

/// De dónde sale una bandera. Hoy solo `rule` (umbrales evaluados en código). El enum existe para
/// que, cuando aparezca una bandera sugerida por un modelo, la UI pueda mostrarla distinto en vez de
/// presentar las dos con el mismo peso.
enum CriteriaSource { rule }

CriteriaSource criteriaSourceFromWire(String? value) => CriteriaSource.rule;

String criteriaSourceCaption(CriteriaSource source) => switch (source) {
      CriteriaSource.rule =>
        'Banderas evaluadas en código con umbrales fijos, no por un modelo. '
            'Cada una muestra el valor medido y el umbral que la disparó.',
    };

/// Quién escribió la prosa. `none` es lo que viaja cuando no hay narrativa: el cliente tiene que
/// poder distinguir "el modelo no dijo nada" de "el modelo dijo que no hay nada que decir".
enum NarrativeSource { llm, none }

NarrativeSource narrativeSourceFromWire(String? value) =>
    value == 'LLM' ? NarrativeSource.llm : NarrativeSource.none;

/// Cómo se derivó el precio implícito de un escenario.
///
/// `peMultipleHeld` es el único método del simulador: se mantiene el múltiplo precio/ganancias y se
/// mueve el EPS. Es una convención para medir sensibilidad, **no una valuación** — y por eso la
/// respuesta la declara en vez de dejarla escondida en el código.
enum ValuationBasis { peMultipleHeld, notApplicable }

ValuationBasis valuationBasisFromWire(String? value) =>
    value == 'PE_MULTIPLE_HELD'
        ? ValuationBasis.peMultipleHeld
        : ValuationBasis.notApplicable;

/// Las tres columnas de la matriz de sensibilidad.
enum ScenarioCase { bear, base, bull }

ScenarioCase scenarioCaseFromWire(String? value) => switch (value) {
      'BEAR' => ScenarioCase.bear,
      'BULL' => ScenarioCase.bull,
      _ => ScenarioCase.base,
    };

enum ConversationRole { user, assistant }

ConversationRole conversationRoleFromWire(String? value) =>
    value == 'USER' ? ConversationRole.user : ConversationRole.assistant;

String conversationRoleToWire(ConversationRole role) =>
    role == ConversationRole.user ? 'USER' : 'ASSISTANT';

// --- Estados contables ---------------------------------------------------------------------------

@immutable
class IncomeStatementBlock {
  const IncomeStatementBlock({
    required this.periodEnd,
    required this.periodLabel,
    required this.revenue,
    required this.grossProfit,
    required this.operatingIncome,
    required this.ebitda,
    required this.ebitdaIsDerived,
    required this.depreciationAmortization,
    required this.interestExpense,
    required this.netIncome,
    required this.epsDiluted,
    required this.grossMarginPct,
    required this.operatingMarginPct,
    required this.ebitdaMarginPct,
    required this.netMarginPct,
    required this.effectiveTaxRatePct,
  });

  factory IncomeStatementBlock.fromJson(Map<String, dynamic> json) =>
      IncomeStatementBlock(
        periodEnd: parseIsoDate(json['period_end']),
        periodLabel: json['period_label'] as String?,
        revenue: parseNumber(json['revenue']),
        grossProfit: parseNumber(json['gross_profit']),
        operatingIncome: parseNumber(json['operating_income']),
        ebitda: parseNumber(json['ebitda']),
        ebitdaIsDerived: json['ebitda_is_derived'] as bool? ?? false,
        depreciationAmortization: parseNumber(json['depreciation_amortization']),
        interestExpense: parseNumber(json['interest_expense']),
        netIncome: parseNumber(json['net_income']),
        epsDiluted: parseNumber(json['eps_diluted']),
        grossMarginPct: parseNumber(json['gross_margin_pct']),
        operatingMarginPct: parseNumber(json['operating_margin_pct']),
        ebitdaMarginPct: parseNumber(json['ebitda_margin_pct']),
        netMarginPct: parseNumber(json['net_margin_pct']),
        effectiveTaxRatePct: parseNumber(json['effective_tax_rate_pct']),
      );

  final DateTime? periodEnd;
  final String? periodLabel;

  final double? revenue;
  final double? grossProfit;
  final double? operatingIncome;

  /// EBITDA. Cuando [ebitdaIsDerived] es `true` lo reconstruyó el backend como resultado operativo +
  /// amortizaciones: puede no coincidir con el que la empresa informa en su presentación, y la UI lo
  /// aclara en vez de presentarlos como la misma cosa.
  final double? ebitda;
  final bool ebitdaIsDerived;

  final double? depreciationAmortization;
  final double? interestExpense;
  final double? netIncome;
  final double? epsDiluted;

  final double? grossMarginPct;
  final double? operatingMarginPct;
  final double? ebitdaMarginPct;
  final double? netMarginPct;
  final double? effectiveTaxRatePct;

  /// Etiqueta del período para mostrar. Prefiere la del proveedor y cae a la fecha de cierre.
  String get label {
    final raw = periodLabel?.trim();
    final end = periodEnd;
    if (end == null) return raw ?? 'período';
    // "FY 2026" y no solo "FY": con cinco filas de "FY" no se distingue una de otra.
    final year = end.year.toString();
    if (raw == null || raw.isEmpty) return year;
    return raw.contains(year) ? raw : '$raw $year';
  }
}

@immutable
class BalanceSheetBlock {
  const BalanceSheetBlock({
    required this.periodEnd,
    required this.periodLabel,
    required this.totalAssets,
    required this.currentAssets,
    required this.cashAndEquivalents,
    required this.totalLiabilities,
    required this.currentLiabilities,
    required this.totalDebt,
    required this.totalEquity,
    required this.currentRatio,
    required this.debtToEquity,
    required this.netDebt,
    required this.equityRatioPct,
  });

  factory BalanceSheetBlock.fromJson(Map<String, dynamic> json) =>
      BalanceSheetBlock(
        periodEnd: parseIsoDate(json['period_end']),
        periodLabel: json['period_label'] as String?,
        totalAssets: parseNumber(json['total_assets']),
        currentAssets: parseNumber(json['current_assets']),
        cashAndEquivalents: parseNumber(json['cash_and_equivalents']),
        totalLiabilities: parseNumber(json['total_liabilities']),
        currentLiabilities: parseNumber(json['current_liabilities']),
        totalDebt: parseNumber(json['total_debt']),
        totalEquity: parseNumber(json['total_equity']),
        currentRatio: parseNumber(json['current_ratio']),
        debtToEquity: parseNumber(json['debt_to_equity']),
        netDebt: parseNumber(json['net_debt']),
        equityRatioPct: parseNumber(json['equity_ratio_pct']),
      );

  final DateTime? periodEnd;
  final String? periodLabel;

  final double? totalAssets;
  final double? currentAssets;
  final double? cashAndEquivalents;
  final double? totalLiabilities;
  final double? currentLiabilities;
  final double? totalDebt;
  final double? totalEquity;

  final double? currentRatio;
  final double? debtToEquity;

  /// Deuda total − caja. **Puede ser negativa y eso es un dato**: significa que la empresa tiene más
  /// caja que deuda.
  final double? netDebt;

  final double? equityRatioPct;

  bool get hasNetCash => netDebt != null && netDebt! < 0;
}

@immutable
class CashFlowBlock {
  const CashFlowBlock({
    required this.periodEnd,
    required this.periodLabel,
    required this.operatingCashFlow,
    required this.capitalExpenditure,
    required this.freeCashFlow,
    required this.freeCashFlowIsDerived,
    required this.fcfConversionPct,
    required this.capexToRevenuePct,
  });

  factory CashFlowBlock.fromJson(Map<String, dynamic> json) => CashFlowBlock(
        periodEnd: parseIsoDate(json['period_end']),
        periodLabel: json['period_label'] as String?,
        operatingCashFlow: parseNumber(json['operating_cash_flow']),
        capitalExpenditure: parseNumber(json['capital_expenditure']),
        freeCashFlow: parseNumber(json['free_cash_flow']),
        freeCashFlowIsDerived: json['free_cash_flow_is_derived'] as bool? ?? false,
        fcfConversionPct: parseNumber(json['fcf_conversion_pct']),
        capexToRevenuePct: parseNumber(json['capex_to_revenue_pct']),
      );

  final DateTime? periodEnd;
  final String? periodLabel;

  final double? operatingCashFlow;
  final double? capitalExpenditure;
  final double? freeCashFlow;
  final bool freeCashFlowIsDerived;

  /// FCF sobre resultado neto. Es la línea que más dice de las tres: una empresa que gana en el papel
  /// y no genera caja tiene un problema que el estado de resultados no muestra.
  final double? fcfConversionPct;

  final double? capexToRevenuePct;
}

/// Descomposición DuPont del ROE: margen neto × rotación de activos × apalancamiento.
///
/// Responde una pregunta que el ROE solo no responde: **de dónde viene** la rentabilidad. Dos
/// empresas con 20% de ROE, una por margen y otra por deuda, son dos inversiones distintas.
@immutable
class DupontBlock {
  const DupontBlock({
    required this.netMarginPct,
    required this.assetTurnover,
    required this.equityMultiplier,
    required this.roePct,
    required this.criteriaSource,
  });

  factory DupontBlock.fromJson(Map<String, dynamic> json) => DupontBlock(
        netMarginPct: parseNumber(json['net_margin_pct']),
        assetTurnover: parseNumber(json['asset_turnover']),
        equityMultiplier: parseNumber(json['equity_multiplier']),
        roePct: parseNumber(json['roe_pct']),
        criteriaSource:
            criteriaSourceFromWire(json['criteria_source'] as String?),
      );

  static const empty = DupontBlock(
    netMarginPct: null,
    assetTurnover: null,
    equityMultiplier: null,
    roePct: null,
    criteriaSource: CriteriaSource.rule,
  );

  final double? netMarginPct;
  final double? assetTurnover;
  final double? equityMultiplier;

  /// El producto de los tres factores, que es algebraicamente el ROE (los cocientes se cancelan).
  final double? roePct;

  final CriteriaSource criteriaSource;

  bool get isComplete =>
      netMarginPct != null && assetTurnover != null && equityMultiplier != null;

  /// Cuál de los tres factores explica más el ROE, para poder señalarlo en la UI.
  ///
  /// Se compara la contribución RELATIVA de cada factor y no su valor absoluto: un margen de 54% y
  /// una rotación de 1,17x no son comparables como números, pero sí lo es cuánto multiplica cada uno.
  /// Sin esto, la pantalla mostraría tres números y dejaría la lectura —que es lo que el DuPont
  /// existe para dar— en manos del usuario.
  DupontDriver? get dominantDriver {
    if (!isComplete) return null;
    // El margen entra como "cuántas veces multiplica" para poder compararlo con los otros dos.
    final margin = (netMarginPct! / 100.0).abs();
    final turnover = assetTurnover!.abs();
    final leverage = equityMultiplier!.abs();

    // La rotación y el apalancamiento se miden contra 1x (el valor neutro): un apalancamiento de
    // 1,0x no aporta nada al ROE, y compararlo crudo contra un margen de 0,54 lo haría "ganar"
    // siempre.
    final scores = <DupontDriver, double>{
      DupontDriver.margin: margin,
      DupontDriver.turnover: (turnover - 1).abs(),
      DupontDriver.leverage: (leverage - 1).abs(),
    };
    return scores.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }
}

/// Los tres factores del DuPont, para poder nombrar el dominante.
enum DupontDriver { margin, turnover, leverage }

String dupontDriverLabel(DupontDriver driver) => switch (driver) {
      DupontDriver.margin => 'el margen',
      DupontDriver.turnover => 'la rotación de activos',
      DupontDriver.leverage => 'el apalancamiento',
    };

/// Una señal contable, con el umbral que la disparó a la vista.
@immutable
class AnalysisFlag {
  const AnalysisFlag({
    required this.code,
    required this.kind,
    required this.severity,
    required this.title,
    required this.detail,
    required this.metricValue,
    required this.threshold,
    required this.criteriaSource,
  });

  factory AnalysisFlag.fromJson(Map<String, dynamic> json) => AnalysisFlag(
        code: json['code'] as String,
        kind: flagKindFromWire(json['kind'] as String?),
        severity: flagSeverityFromWire(json['severity'] as String?),
        title: json['title'] as String,
        detail: json['detail'] as String,
        metricValue: parseNumber(json['metric_value']),
        threshold: parseNumber(json['threshold']),
        criteriaSource:
            criteriaSourceFromWire(json['criteria_source'] as String?),
      );

  final String code;
  final FlagKind kind;
  final FlagSeverity severity;
  final String title;

  /// Incluye SIEMPRE el valor medido y el umbral, ya redactado por el backend: "Deuda/Patrimonio de
  /// 5,00x (umbral 4,00x)" es verificable y discutible; "apalancamiento alto" es una opinión.
  final String detail;

  final double? metricValue;
  final double? threshold;
  final CriteriaSource criteriaSource;
}

@immutable
class ConversationTurn {
  const ConversationTurn({required this.role, required this.content});

  factory ConversationTurn.fromJson(Map<String, dynamic> json) =>
      ConversationTurn(
        role: conversationRoleFromWire(json['role'] as String?),
        content: json['content'] as String,
      );

  final ConversationRole role;
  final String content;

  Map<String, dynamic> toJson() => {
        'role': conversationRoleToWire(role),
        'content': content,
      };

  bool get isUser => role == ConversationRole.user;
}

@immutable
class FinancialAnalysisResponse {
  const FinancialAnalysisResponse({
    required this.ticker,
    required this.companyName,
    required this.period,
    required this.generatedAt,
    required this.incomeStatements,
    required this.balanceSheets,
    required this.cashFlows,
    required this.dupont,
    required this.flags,
    required this.narrative,
    required this.narrativeSource,
    required this.history,
    required this.availability,
    required this.degradationReason,
    required this.narrativeDegradationReason,
    required this.servedFromCache,
  });

  factory FinancialAnalysisResponse.fromJson(Map<String, dynamic> json) =>
      FinancialAnalysisResponse(
        ticker: json['ticker'] as String,
        companyName: json['company_name'] as String?,
        period: statementPeriodFromWire(json['period'] as String?),
        generatedAt:
            DateTime.tryParse(json['generated_at'] as String? ?? '') ??
                DateTime.now(),
        incomeStatements: _list(
          json['income_statements'],
          IncomeStatementBlock.fromJson,
        ),
        balanceSheets: _list(json['balance_sheets'], BalanceSheetBlock.fromJson),
        cashFlows: _list(json['cash_flows'], CashFlowBlock.fromJson),
        dupont: json['dupont'] == null
            ? DupontBlock.empty
            : DupontBlock.fromJson(json['dupont'] as Map<String, dynamic>),
        flags: _list(json['flags'], AnalysisFlag.fromJson),
        narrative: json['narrative'] as String?,
        narrativeSource:
            narrativeSourceFromWire(json['narrative_source'] as String?),
        history: _list(json['history'], ConversationTurn.fromJson),
        availability: availabilityFromWire(json['availability'] as String?),
        degradationReason: json['degradation_reason'] as String?,
        narrativeDegradationReason:
            json['narrative_degradation_reason'] as String?,
        servedFromCache: json['served_from_cache'] as bool? ?? false,
      );

  final String ticker;
  final String? companyName;
  final StatementPeriod period;
  final DateTime generatedAt;

  /// Del más reciente al más viejo. Son listas PARALELAS y no una lista de tripletas: los tres
  /// estados pueden traer distinta cantidad de períodos, y aparearlos a la fuerza obligaría a
  /// inventar filas vacías.
  final List<IncomeStatementBlock> incomeStatements;
  final List<BalanceSheetBlock> balanceSheets;
  final List<CashFlowBlock> cashFlows;

  final DupontBlock dupont;
  final List<AnalysisFlag> flags;

  final String? narrative;
  final NarrativeSource narrativeSource;

  /// El hilo completo, con la pregunta y la respuesta de este turno ya agregadas por el backend. Se
  /// usa TAL CUAL en el próximo request: reconstruirlo del lado del cliente arriesgaría mandar un
  /// historial que no coincide con lo que el backend efectivamente vio.
  final List<ConversationTurn> history;

  final DataAvailability availability;
  final String? degradationReason;

  /// Motivo SEPARADO del general: sin modelo, los números y las banderas están completos y lo único
  /// que falta es la prosa. Un solo campo obligaría a elegir cuál de las dos cosas contar.
  final String? narrativeDegradationReason;

  final bool servedFromCache;

  bool get hasStatements =>
      incomeStatements.isNotEmpty ||
      balanceSheets.isNotEmpty ||
      cashFlows.isNotEmpty;

  IncomeStatementBlock? get latestIncome =>
      incomeStatements.isEmpty ? null : incomeStatements.first;

  BalanceSheetBlock? get latestBalance =>
      balanceSheets.isEmpty ? null : balanceSheets.first;

  CashFlowBlock? get latestCashFlow =>
      cashFlows.isEmpty ? null : cashFlows.first;

  List<AnalysisFlag> get redFlags =>
      flags.where((flag) => flag.kind == FlagKind.red).toList();

  List<AnalysisFlag> get greenFlags =>
      flags.where((flag) => flag.kind == FlagKind.green).toList();
}

// --- Simulador -----------------------------------------------------------------------------------

/// Las palancas del escenario.
///
/// **Todas son opcionales y `null` NO es cero.** La diferencia importa en dos de las cuatro:
///
///   - Sin `ebitdaMarginPct`, el backend parte del margen del período base y le descuenta la
///     inflación que no se traspasa a precios. Con un margen explícito, ese margen manda y la
///     inflación no le resta nada.
///   - Sin `interestRatePct`, el gasto de intereses queda igual al del período base. Con una tasa, se
///     recalcula sobre la deuda del balance.
///
/// Por eso la UI las trata como "sin fijar" hasta que el usuario las activa, en vez de arrancar con
/// un valor por defecto que ya sería un supuesto suyo.
@immutable
class ScenarioVariables {
  const ScenarioVariables({
    this.revenueGrowthPct,
    this.ebitdaMarginPct,
    this.interestRatePct,
    this.inflationPct,
    this.customEvent,
  });

  factory ScenarioVariables.fromJson(Map<String, dynamic> json) =>
      ScenarioVariables(
        revenueGrowthPct: parseNumber(json['revenue_growth_pct']),
        ebitdaMarginPct: parseNumber(json['ebitda_margin_pct']),
        interestRatePct: parseNumber(json['interest_rate_pct']),
        inflationPct: parseNumber(json['inflation_pct']),
        customEvent: json['custom_event'] as String?,
      );

  final double? revenueGrowthPct;
  final double? ebitdaMarginPct;
  final double? interestRatePct;
  final double? inflationPct;

  /// El evento o rumor en lenguaje natural. **No entra en ninguna fórmula**: su efecto es
  /// cualitativo y la respuesta lo declara.
  final String? customEvent;

  /// El cuerpo del request. Las claves ausentes son la forma de decir "no fijes esta variable", así
  /// que un `null` NO se manda: mandarlo sería fijarla en null, que el backend rechaza.
  Map<String, dynamic> toJson() => {
        if (revenueGrowthPct != null) 'revenue_growth_pct': revenueGrowthPct,
        if (ebitdaMarginPct != null) 'ebitda_margin_pct': ebitdaMarginPct,
        if (interestRatePct != null) 'interest_rate_pct': interestRatePct,
        if (inflationPct != null) 'inflation_pct': inflationPct,
        if (customEvent != null && customEvent!.trim().isNotEmpty)
          'custom_event': customEvent!.trim(),
      };

  ScenarioVariables copyWith({
    bool clearGrowth = false,
    double? revenueGrowthPct,
    bool clearMargin = false,
    double? ebitdaMarginPct,
    bool clearInterest = false,
    double? interestRatePct,
    bool clearInflation = false,
    double? inflationPct,
    bool clearEvent = false,
    String? customEvent,
  }) =>
      ScenarioVariables(
        revenueGrowthPct:
            clearGrowth ? null : (revenueGrowthPct ?? this.revenueGrowthPct),
        ebitdaMarginPct:
            clearMargin ? null : (ebitdaMarginPct ?? this.ebitdaMarginPct),
        interestRatePct:
            clearInterest ? null : (interestRatePct ?? this.interestRatePct),
        inflationPct:
            clearInflation ? null : (inflationPct ?? this.inflationPct),
        customEvent: clearEvent ? null : (customEvent ?? this.customEvent),
      );

  /// ¿Hay alguna palanca que mueva las cuentas?
  ///
  /// Un escenario con SOLO un rumor es válido y se responde, pero su proyección es igual a la base —
  /// y la UI tiene que poder decirlo en vez de mostrar un 0% como si fuera el resultado del análisis.
  bool get hasQuantitativeLever =>
      revenueGrowthPct != null ||
      ebitdaMarginPct != null ||
      interestRatePct != null ||
      inflationPct != null;

  bool get hasCustomEvent =>
      customEvent != null && customEvent!.trim().isNotEmpty;

  bool get isEmpty => !hasQuantitativeLever && !hasCustomEvent;

  @override
  bool operator ==(Object other) =>
      other is ScenarioVariables &&
      other.revenueGrowthPct == revenueGrowthPct &&
      other.ebitdaMarginPct == ebitdaMarginPct &&
      other.interestRatePct == interestRatePct &&
      other.inflationPct == inflationPct &&
      other.customEvent == customEvent;

  @override
  int get hashCode => Object.hash(
        revenueGrowthPct,
        ebitdaMarginPct,
        interestRatePct,
        inflationPct,
        customEvent,
      );
}

@immutable
class ScenarioBaseline {
  const ScenarioBaseline({
    required this.periodEnd,
    required this.periodLabel,
    required this.period,
    required this.revenue,
    required this.ebitda,
    required this.ebitdaMarginPct,
    required this.interestExpense,
    required this.totalDebt,
    required this.impliedInterestRatePct,
    required this.effectiveTaxRatePct,
    required this.netIncome,
    required this.eps,
    required this.modelEps,
    required this.sharesOutstanding,
    required this.freeCashFlow,
    required this.referencePrice,
    required this.priceEarningsMultiple,
  });

  factory ScenarioBaseline.fromJson(Map<String, dynamic> json) =>
      ScenarioBaseline(
        periodEnd: parseIsoDate(json['period_end']),
        periodLabel: json['period_label'] as String?,
        period: statementPeriodFromWire(json['period'] as String?),
        revenue: parseNumber(json['revenue']),
        ebitda: parseNumber(json['ebitda']),
        ebitdaMarginPct: parseNumber(json['ebitda_margin_pct']),
        interestExpense: parseNumber(json['interest_expense']),
        totalDebt: parseNumber(json['total_debt']),
        impliedInterestRatePct: parseNumber(json['implied_interest_rate_pct']),
        effectiveTaxRatePct: parseNumber(json['effective_tax_rate_pct']),
        netIncome: parseNumber(json['net_income']),
        eps: parseNumber(json['eps']),
        modelEps: parseNumber(json['model_eps']),
        sharesOutstanding: parseNumber(json['shares_outstanding']),
        freeCashFlow: parseNumber(json['free_cash_flow']),
        referencePrice: parseNumber(json['reference_price']),
        priceEarningsMultiple: parseNumber(json['price_earnings_multiple']),
      );

  static const empty = ScenarioBaseline(
    periodEnd: null,
    periodLabel: null,
    period: StatementPeriod.annual,
    revenue: null,
    ebitda: null,
    ebitdaMarginPct: null,
    interestExpense: null,
    totalDebt: null,
    impliedInterestRatePct: null,
    effectiveTaxRatePct: null,
    netIncome: null,
    eps: null,
    modelEps: null,
    sharesOutstanding: null,
    freeCashFlow: null,
    referencePrice: null,
    priceEarningsMultiple: null,
  );

  final DateTime? periodEnd;
  final String? periodLabel;
  final StatementPeriod period;

  final double? revenue;
  final double? ebitda;
  final double? ebitdaMarginPct;
  final double? interestExpense;
  final double? totalDebt;
  final double? impliedInterestRatePct;
  final double? effectiveTaxRatePct;
  final double? netIncome;

  /// El EPS que la empresa reportó.
  final double? eps;

  /// El EPS que produce la cascada del simulador SIN mover nada, y contra el que se miden todas las
  /// variaciones.
  ///
  /// No coincide con [eps] y esa diferencia es esperable: la cascada modela EBITDA → amortizaciones →
  /// intereses → impuestos, y una empresa real tiene además resultados no operativos. Los dos viajan
  /// porque cumplen funciones distintas, y la UI muestra los dos cuando difieren.
  final double? modelEps;

  final double? sharesOutstanding;
  final double? freeCashFlow;
  final double? referencePrice;
  final double? priceEarningsMultiple;

  /// ¿El punto cero del modelo se separa de lo reportado? Decide si vale mostrar los dos.
  bool get modelEpsDiffers {
    final reported = eps;
    final model = modelEps;
    if (reported == null || model == null) return false;
    return (reported - model).abs() > 0.005;
  }
}

@immutable
class ScenarioProjection {
  const ScenarioProjection({
    required this.revenue,
    required this.ebitda,
    required this.ebitdaMarginPct,
    required this.operatingIncome,
    required this.interestExpense,
    required this.netIncome,
    required this.eps,
    required this.freeCashFlow,
    required this.revenueChangePct,
    required this.ebitdaChangePct,
    required this.epsChangePct,
    required this.freeCashFlowChangePct,
    required this.impliedPrice,
    required this.impliedPriceChangePct,
  });

  factory ScenarioProjection.fromJson(Map<String, dynamic> json) =>
      ScenarioProjection(
        revenue: parseNumber(json['revenue']),
        ebitda: parseNumber(json['ebitda']),
        ebitdaMarginPct: parseNumber(json['ebitda_margin_pct']),
        operatingIncome: parseNumber(json['operating_income']),
        interestExpense: parseNumber(json['interest_expense']),
        netIncome: parseNumber(json['net_income']),
        eps: parseNumber(json['eps']),
        freeCashFlow: parseNumber(json['free_cash_flow']),
        revenueChangePct: parseNumber(json['revenue_change_pct']),
        ebitdaChangePct: parseNumber(json['ebitda_change_pct']),
        epsChangePct: parseNumber(json['eps_change_pct']),
        freeCashFlowChangePct: parseNumber(json['free_cash_flow_change_pct']),
        impliedPrice: parseNumber(json['implied_price']),
        impliedPriceChangePct: parseNumber(json['implied_price_change_pct']),
      );

  static const empty = ScenarioProjection(
    revenue: null,
    ebitda: null,
    ebitdaMarginPct: null,
    operatingIncome: null,
    interestExpense: null,
    netIncome: null,
    eps: null,
    freeCashFlow: null,
    revenueChangePct: null,
    ebitdaChangePct: null,
    epsChangePct: null,
    freeCashFlowChangePct: null,
    impliedPrice: null,
    impliedPriceChangePct: null,
  );

  final double? revenue;
  final double? ebitda;
  final double? ebitdaMarginPct;
  final double? operatingIncome;
  final double? interestExpense;
  final double? netIncome;
  final double? eps;
  final double? freeCashFlow;

  final double? revenueChangePct;
  final double? ebitdaChangePct;
  final double? epsChangePct;
  final double? freeCashFlowChangePct;

  /// Precio que resultaría de mantener el múltiplo y mover el EPS. `null` cuando no hay múltiplo que
  /// sostener; **nunca 0**.
  final double? impliedPrice;
  final double? impliedPriceChangePct;
}

@immutable
class SensitivityCase {
  const SensitivityCase({
    required this.scenarioCase,
    required this.label,
    required this.variables,
    required this.projection,
  });

  factory SensitivityCase.fromJson(Map<String, dynamic> json) => SensitivityCase(
        scenarioCase: scenarioCaseFromWire(json['case'] as String?),
        label: json['label'] as String,
        variables: ScenarioVariables.fromJson(
          (json['variables'] as Map<String, dynamic>?) ?? const {},
        ),
        projection: ScenarioProjection.fromJson(
          (json['projection'] as Map<String, dynamic>?) ?? const {},
        ),
      );

  final ScenarioCase scenarioCase;
  final String label;

  /// Las variables que produjeron el caso. Viajan con el resultado para que sea reproducible: un
  /// "bear" con −18% de EPS no dice nada si no se puede ver de qué supuestos salió.
  final ScenarioVariables variables;

  final ScenarioProjection projection;
}

@immutable
class ScenarioSimulationResult {
  const ScenarioSimulationResult({
    required this.ticker,
    required this.companyName,
    required this.generatedAt,
    required this.baseline,
    required this.appliedVariables,
    required this.projection,
    required this.sensitivity,
    required this.valuationBasis,
    required this.valuationNote,
    required this.modelAssumptions,
    required this.customEvent,
    required this.customEventIsQualitative,
    required this.narrative,
    required this.narrativeSource,
    required this.availability,
    required this.degradationReason,
    required this.narrativeDegradationReason,
    required this.servedFromCache,
  });

  factory ScenarioSimulationResult.fromJson(Map<String, dynamic> json) =>
      ScenarioSimulationResult(
        ticker: json['ticker'] as String,
        companyName: json['company_name'] as String?,
        generatedAt:
            DateTime.tryParse(json['generated_at'] as String? ?? '') ??
                DateTime.now(),
        baseline: json['baseline'] == null
            ? ScenarioBaseline.empty
            : ScenarioBaseline.fromJson(
                json['baseline'] as Map<String, dynamic>,
              ),
        appliedVariables: ScenarioVariables.fromJson(
          (json['applied_variables'] as Map<String, dynamic>?) ?? const {},
        ),
        projection: json['projection'] == null
            ? ScenarioProjection.empty
            : ScenarioProjection.fromJson(
                json['projection'] as Map<String, dynamic>,
              ),
        sensitivity: _list(json['sensitivity'], SensitivityCase.fromJson),
        valuationBasis:
            valuationBasisFromWire(json['valuation_basis'] as String?),
        valuationNote: json['valuation_note'] as String?,
        modelAssumptions: ((json['model_assumptions'] as List?) ?? const [])
            .map((item) => item as String)
            .toList(),
        customEvent: json['custom_event'] as String?,
        customEventIsQualitative:
            json['custom_event_is_qualitative'] as bool? ?? true,
        narrative: json['narrative'] as String?,
        narrativeSource:
            narrativeSourceFromWire(json['narrative_source'] as String?),
        availability: availabilityFromWire(json['availability'] as String?),
        degradationReason: json['degradation_reason'] as String?,
        narrativeDegradationReason:
            json['narrative_degradation_reason'] as String?,
        servedFromCache: json['served_from_cache'] as bool? ?? false,
      );

  final String ticker;
  final String? companyName;
  final DateTime generatedAt;

  final ScenarioBaseline baseline;
  final ScenarioVariables appliedVariables;
  final ScenarioProjection projection;
  final List<SensitivityCase> sensitivity;

  final ValuationBasis valuationBasis;

  /// Cómo se derivó el precio, o por qué no se pudo. Se muestra SIEMPRE: los motivos posibles se
  /// arreglan distinto y ninguno es "no hay dato".
  final String? valuationNote;

  /// Qué se mantuvo constante, con qué tasa se gravó y de dónde sale el múltiplo. **No es
  /// decorativo**: una proyección sin sus supuestos tiene la autoridad de un pronóstico y la solidez
  /// de una cuenta al margen.
  final List<String> modelAssumptions;

  final String? customEvent;

  /// `true` cuando el evento en texto NO movió ningún número. Sin mostrarlo, alguien que escribe
  /// "pierden el juicio" y ve un EPS proyectado creería que el sistema cuantificó el juicio.
  final bool customEventIsQualitative;

  final String? narrative;
  final NarrativeSource narrativeSource;

  final DataAvailability availability;
  final String? degradationReason;
  final String? narrativeDegradationReason;
  final bool servedFromCache;

  SensitivityCase? caseOf(ScenarioCase kind) {
    for (final item in sensitivity) {
      if (item.scenarioCase == kind) return item;
    }
    return null;
  }

  bool get hasProjection => projection.eps != null || projection.revenue != null;
}

// --- Parseo tolerante ----------------------------------------------------------------------------

List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) parse) {
  if (raw is! List) return <T>[];
  return raw
      .whereType<Map<String, dynamic>>()
      .map(parse)
      .toList(growable: false);
}

/// Los números del contrato son `float | null`, pero un entero grande (los ingresos en dólares)
/// llega como `int` en Dart y un cast directo a `double` explota. Se convierte en vez de castear.
double? parseNumber(Object? raw) => switch (raw) {
      final double value => value,
      final int value => value.toDouble(),
      _ => null,
    };

DateTime? parseIsoDate(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}
