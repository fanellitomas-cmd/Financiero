import '../../../core/data/data_availability.dart';

/// Modelos de `/api/v1/portfolio-builder/simulate` (`app/schemas/portfolio_builder.py`).
///
/// Tres cosas del contrato que la UI tiene que respetar y no puede deducir sola:
///
///   - **Las unidades son enteras** y la fracción que no llega queda en `cashUnallocated`. El backend
///     lo declara en `unitRounding` en vez de dejarlo implícito en las cuentas.
///   - **El retorno a 1 año se mide contra precios reales** incluso en las posiciones con precio
///     esperado; lo que cambia con el precio esperado son los pesos. La pantalla tiene que decirlo.
///   - **`returnCoveragePct` no es decoración**: un retorno medido sobre el 40% del capital no se
///     puede mostrar con la misma autoridad que uno medido entero.

/// Cómo se expresa el tamaño de una posición.
enum AllocationType { units, amountUsd, percentage }

AllocationType allocationTypeFromWire(String? value) => switch (value) {
      'AMOUNT_USD' => AllocationType.amountUsd,
      'PERCENTAGE' => AllocationType.percentage,
      _ => AllocationType.units,
    };

String allocationTypeToWire(AllocationType type) => switch (type) {
      AllocationType.units => 'UNITS',
      AllocationType.amountUsd => 'AMOUNT_USD',
      AllocationType.percentage => 'PERCENTAGE',
    };

String allocationTypeLabel(AllocationType type) => switch (type) {
      AllocationType.units => 'Unidades',
      AllocationType.amountUsd => 'Monto US\$',
      AllocationType.percentage => '% del presupuesto',
    };

/// Sufijo que acompaña al valor en el campo numérico. Sin él, "20" es ambiguo entre 20 acciones,
/// 20 dólares y 20 por ciento.
String allocationTypeSuffix(AllocationType type) => switch (type) {
      AllocationType.units => 'u',
      AllocationType.amountUsd => 'US\$',
      AllocationType.percentage => '%',
    };

/// De dónde salió el precio con el que se calculó la posición.
enum PriceSource { market, custom, unavailable }

PriceSource priceSourceFromWire(String? value) => switch (value) {
      'CUSTOM' => PriceSource.custom,
      'MARKET' => PriceSource.market,
      _ => PriceSource.unavailable,
    };

/// Nivel de concentración. Es la MISMA escala que la Auditoría de Portafolio: la misma cartera no
/// puede leerse "alta" en una pantalla y "crítica" en la otra.
enum RiskLevel { baja, moderada, alta, critica }

RiskLevel? riskLevelFromWire(String? value) => switch (value) {
      'BAJA' => RiskLevel.baja,
      'MODERADA' => RiskLevel.moderada,
      'ALTA' => RiskLevel.alta,
      'CRITICA' => RiskLevel.critica,
      _ => null,
    };

String riskLevelLabel(RiskLevel level) => switch (level) {
      RiskLevel.baja => 'Baja',
      RiskLevel.moderada => 'Moderada',
      RiskLevel.alta => 'Alta',
      RiskLevel.critica => 'Crítica',
    };

/// Sobre qué se calcularon los porcentajes. El Constructor siempre pondera por capital; la Auditoría,
/// por cantidad de símbolos. Que el campo viaje es lo que evita comparar un 40% con el otro.
enum WeightingBasis { equalWeightByCount, marketValue }

WeightingBasis weightingBasisFromWire(String? value) =>
    value == 'EQUAL_WEIGHT_BY_COUNT'
        ? WeightingBasis.equalWeightByCount
        : WeightingBasis.marketValue;

/// Qué se hizo con la fracción de unidad que no llega a entera.
enum UnitRounding { floorToWholeUnits }

/// Convierte un número del JSON a `double`.
///
/// Un porcentaje redondo puede llegar como `int` (`20`, no `20.0`): JSON no distingue, y un cast
/// directo a `double` explotaría.
double? parseNumber(Object? value) => switch (value) {
      final num number => number.toDouble(),
      _ => null,
    };

DateTime? _parseDate(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

/// Una posición tal como la pide el usuario. Es lo único que viaja al backend.
class PortfolioItemInput {
  const PortfolioItemInput({
    required this.ticker,
    required this.allocationType,
    required this.allocationValue,
    this.assetType = 'STOCK',
    this.customPrice,
    this.name,
  });

  final String ticker;
  final String assetType;
  final AllocationType allocationType;
  final double allocationValue;

  /// `null` = usar el precio de mercado. **No es lo mismo que 0**: un 0 sería un precio esperado de
  /// cero, que el backend rechaza con 422.
  final double? customPrice;

  /// Nombre resuelto por el buscador, para mostrarlo mientras la simulación todavía no volvió. No
  /// viaja al backend: el servidor lo resuelve del catálogo.
  final String? name;

  bool get usesCustomPrice => customPrice != null;

  PortfolioItemInput copyWith({
    AllocationType? allocationType,
    double? allocationValue,
    Object? customPrice = _unset,
  }) =>
      PortfolioItemInput(
        ticker: ticker,
        assetType: assetType,
        name: name,
        allocationType: allocationType ?? this.allocationType,
        allocationValue: allocationValue ?? this.allocationValue,
        customPrice:
            customPrice == _unset ? this.customPrice : customPrice as double?,
      );

  Map<String, dynamic> toJson() => {
        'ticker': ticker,
        'asset_type': assetType,
        'allocation_type': allocationTypeToWire(allocationType),
        'allocation_value': allocationValue,
        // La clave se OMITE cuando no hay precio esperado. Mandar `null` explícito sería fijarlo en
        // null, y el schema del backend lo rechaza.
        if (customPrice != null) 'custom_price': customPrice,
      };

  @override
  bool operator ==(Object other) =>
      other is PortfolioItemInput &&
      other.ticker == ticker &&
      other.assetType == assetType &&
      other.allocationType == allocationType &&
      other.allocationValue == allocationValue &&
      other.customPrice == customPrice;

  @override
  int get hashCode =>
      Object.hash(ticker, assetType, allocationType, allocationValue, customPrice);
}

const Object _unset = Object();

/// El pedido completo: presupuesto y posiciones.
class PortfolioSimulationRequest {
  const PortfolioSimulationRequest({
    required this.totalBudget,
    required this.items,
  });

  final double totalBudget;
  final List<PortfolioItemInput> items;

  Map<String, dynamic> toJson() => {
        'total_budget': totalBudget,
        'items': items.map((item) => item.toJson()).toList(),
      };

  @override
  bool operator ==(Object other) =>
      other is PortfolioSimulationRequest &&
      other.totalBudget == totalBudget &&
      _listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(totalBudget, Object.hashAll(items));
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

/// Una posición ya resuelta por el backend.
class PortfolioAllocationItem {
  const PortfolioAllocationItem({
    required this.ticker,
    required this.sector,
    required this.sectorLabel,
    required this.priceSource,
    required this.units,
    required this.investedAmount,
    required this.percentageOfTotal,
    this.name,
    this.marketPrice,
    this.effectivePrice,
    this.isCustomPrice = false,
    this.return1yPct,
    this.return1yFromDate,
    this.note,
  });

  factory PortfolioAllocationItem.fromJson(Map<String, dynamic> json) =>
      PortfolioAllocationItem(
        ticker: json['ticker'] as String? ?? '',
        name: json['name'] as String?,
        sector: json['sector'] as String? ?? 'SIN_CLASIFICAR',
        sectorLabel: json['sector_label'] as String? ?? 'Sin clasificar',
        marketPrice: parseNumber(json['market_price']),
        effectivePrice: parseNumber(json['effective_price']),
        isCustomPrice: json['is_custom_price'] as bool? ?? false,
        priceSource: priceSourceFromWire(json['price_source'] as String?),
        units: (json['units'] as num?)?.toInt() ?? 0,
        investedAmount: parseNumber(json['invested_amount']) ?? 0,
        percentageOfTotal: parseNumber(json['percentage_of_total']) ?? 0,
        return1yPct: parseNumber(json['return_1y_pct']),
        return1yFromDate: _parseDate(json['return_1y_from_date']),
        note: json['note'] as String?,
      );

  final String ticker;
  final String? name;
  final String sector;
  final String sectorLabel;

  final double? marketPrice;
  final double? effectivePrice;
  final bool isCustomPrice;
  final PriceSource priceSource;

  final int units;
  final double investedAmount;
  final double percentageOfTotal;

  final double? return1yPct;
  final DateTime? return1yFromDate;
  final String? note;

  /// La posición no entró en la cartera. Se muestra igual, con su motivo: sacarla de la lista dejaría
  /// al usuario buscando un símbolo que él agregó y que desapareció sin explicación.
  bool get isEmpty => units == 0;

  /// Cuánto se apartó el precio esperado del de mercado. `null` cuando no hay con qué comparar.
  double? get customPriceGapPct {
    final market = marketPrice;
    final effective = effectivePrice;
    if (!isCustomPrice || market == null || effective == null || market <= 0) {
      return null;
    }
    return (effective - market) / market * 100;
  }
}

/// Peso de un sector medido en capital invertido.
class SectorAmountAllocation {
  const SectorAmountAllocation({
    required this.sector,
    required this.label,
    required this.amount,
    required this.percentageOfTotal,
    required this.tickerCount,
    this.tickers = const [],
  });

  factory SectorAmountAllocation.fromJson(Map<String, dynamic> json) =>
      SectorAmountAllocation(
        sector: json['sector'] as String? ?? 'SIN_CLASIFICAR',
        label: json['label'] as String? ?? 'Sin clasificar',
        amount: parseNumber(json['amount']) ?? 0,
        percentageOfTotal: parseNumber(json['percentage_of_total']) ?? 0,
        tickerCount: (json['ticker_count'] as num?)?.toInt() ?? 0,
        tickers: (json['tickers'] as List<dynamic>? ?? const [])
            .map((value) => value as String)
            .toList(),
      );

  final String sector;
  final String label;
  final double amount;
  final double percentageOfTotal;
  final int tickerCount;
  final List<String> tickers;
}

/// El resultado completo de la simulación.
class PortfolioSimulationResult {
  const PortfolioSimulationResult({
    required this.generatedAt,
    required this.totalBudget,
    required this.allocatedAmount,
    required this.cashUnallocated,
    required this.cashPct,
    required this.availability,
    this.overBudgetAmount,
    this.items = const [],
    this.sectorAllocation = const [],
    this.weightingBasis = WeightingBasis.marketValue,
    this.portfolioReturn1yPct,
    this.returnCoveragePct = 0,
    this.riskScore,
    this.herfindahlIndex,
    this.topSector,
    this.topSectorWeightPct,
    this.riskNotes = const [],
    this.unitRounding = UnitRounding.floorToWholeUnits,
    this.degradationReason,
    this.notes = const [],
  });

  factory PortfolioSimulationResult.fromJson(Map<String, dynamic> json) =>
      PortfolioSimulationResult(
        generatedAt:
            _parseDate(json['generated_at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
        totalBudget: parseNumber(json['total_budget']) ?? 0,
        allocatedAmount: parseNumber(json['allocated_amount']) ?? 0,
        cashUnallocated: parseNumber(json['cash_unallocated']) ?? 0,
        cashPct: parseNumber(json['cash_pct']) ?? 0,
        overBudgetAmount: parseNumber(json['over_budget_amount']),
        items: (json['items'] as List<dynamic>? ?? const [])
            .map((value) =>
                PortfolioAllocationItem.fromJson(value as Map<String, dynamic>))
            .toList(),
        sectorAllocation:
            (json['sector_allocation'] as List<dynamic>? ?? const [])
                .map((value) =>
                    SectorAmountAllocation.fromJson(value as Map<String, dynamic>))
                .toList(),
        weightingBasis: weightingBasisFromWire(json['weighting_basis'] as String?),
        portfolioReturn1yPct: parseNumber(json['portfolio_return_1y_pct']),
        returnCoveragePct: parseNumber(json['return_coverage_pct']) ?? 0,
        riskScore: riskLevelFromWire(json['risk_score'] as String?),
        herfindahlIndex: parseNumber(json['herfindahl_index']),
        topSector: json['top_sector'] as String?,
        topSectorWeightPct: parseNumber(json['top_sector_weight_pct']),
        riskNotes: (json['risk_notes'] as List<dynamic>? ?? const [])
            .map((value) => value as String)
            .toList(),
        availability:
            availabilityFromWire(json['availability'] as String?),
        degradationReason: json['degradation_reason'] as String?,
        notes: (json['notes'] as List<dynamic>? ?? const [])
            .map((value) => value as String)
            .toList(),
      );

  final DateTime generatedAt;

  final double totalBudget;
  final double allocatedAmount;
  final double cashUnallocated;
  final double cashPct;

  /// Cuánto se pasó lo pedido por encima del presupuesto. `null` cuando entra.
  final double? overBudgetAmount;

  final List<PortfolioAllocationItem> items;
  final List<SectorAmountAllocation> sectorAllocation;
  final WeightingBasis weightingBasis;

  final double? portfolioReturn1yPct;

  /// Qué porcentaje del capital asignado tiene retorno medible.
  final double returnCoveragePct;

  final RiskLevel? riskScore;
  final double? herfindahlIndex;
  final String? topSector;
  final double? topSectorWeightPct;
  final List<String> riskNotes;

  final UnitRounding unitRounding;

  final DataAvailability availability;
  final String? degradationReason;
  final List<String> notes;

  /// Posiciones que efectivamente entraron, de mayor a menor peso. Es lo que alimenta la torta: una
  /// posición en 0 no tiene porción que dibujar.
  List<PortfolioAllocationItem> get funded {
    final list = items.where((item) => item.investedAmount > 0).toList()
      ..sort((a, b) => b.investedAmount.compareTo(a.investedAmount));
    return list;
  }

  List<PortfolioAllocationItem> get unfunded =>
      items.where((item) => item.investedAmount <= 0).toList();

  bool get hasAllocation => funded.isNotEmpty;

  /// El retorno se midió sobre TODO el capital asignado. Cuando es `false`, el número existe pero
  /// describe solo una parte de la cartera y la pantalla tiene que decirlo.
  bool get returnIsComplete => returnCoveragePct >= 99.5;

  bool get isOverBudget => overBudgetAmount != null;
}
