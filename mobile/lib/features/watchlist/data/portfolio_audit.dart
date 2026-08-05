/// Modelos de `GET/POST /api/v1/watchlist/audit` — la Auditoría de Portafolio por IA.
///
/// Espejan `app/schemas/portfolio_audit.py`. Mismo principio de parseo que la Ficha de
/// Inteligencia Profunda: **todo enum del backend se parsea con fallback, nunca con `throw`**. Un
/// sector nuevo del lado del servidor tiene que degradar ese dato puntual, no tirar abajo la
/// auditoría entera.
///
/// La aclaración que atraviesa todo este archivo: los porcentajes son **equiponderados por
/// cantidad de activos**, no por dinero invertido — la watchlist no guarda cantidades ni precio de
/// compra. Por eso `weightingBasis` viaja en el contrato y la UI lo dice explícito: "40% en
/// Tecnología" acá significa 4 de cada 10 activos seguidos, no 40 centavos de cada peso.
library;

import 'package:flutter/foundation.dart';

import '../../../core/data/data_availability.dart';

export '../../../core/data/data_availability.dart'
    show DataAvailability, availabilityFromWire;

/// Sector en el vocabulario del producto. El backend normaliza el del proveedor
/// (`Technology` -> `TECNOLOGIA`) para que la UI pueda agrupar y colorear por un vocabulario
/// cerrado.
///
/// `sinClasificar` es el fallback y también un valor legítimo del backend: un símbolo cuyo sector
/// no se pudo resolver aparece así en vez de desaparecer de la torta.
enum PortfolioSector {
  tecnologia,
  salud,
  serviciosFinancieros,
  consumoDiscrecional,
  consumoBasico,
  industria,
  energia,
  materiales,
  serviciosPublicos,
  bienesRaices,
  comunicaciones,
  cripto,
  sinClasificar,
}

PortfolioSector sectorFromWire(String? value) => switch (value) {
      'TECNOLOGIA' => PortfolioSector.tecnologia,
      'SALUD' => PortfolioSector.salud,
      'SERVICIOS_FINANCIEROS' => PortfolioSector.serviciosFinancieros,
      'CONSUMO_DISCRECIONAL' => PortfolioSector.consumoDiscrecional,
      'CONSUMO_BASICO' => PortfolioSector.consumoBasico,
      'INDUSTRIA' => PortfolioSector.industria,
      'ENERGIA' => PortfolioSector.energia,
      'MATERIALES' => PortfolioSector.materiales,
      'SERVICIOS_PUBLICOS' => PortfolioSector.serviciosPublicos,
      'BIENES_RAICES' => PortfolioSector.bienesRaices,
      'COMUNICACIONES' => PortfolioSector.comunicaciones,
      'CRIPTO' => PortfolioSector.cripto,
      _ => PortfolioSector.sinClasificar,
    };

/// Nivel de concentración. El backend lo calcula con umbrales explícitos sobre el peso del sector
/// dominante y el índice de Herfindahl, tomando el peor de los dos — no se lo pide al modelo, así
/// que la misma cartera da siempre el mismo veredicto.
enum RiskLevel { baja, moderada, alta, critica }

/// `moderada` como fallback y no `baja`: ante un valor que este cliente no conoce, la afirmación
/// prudente no es "tu cartera está bien".
RiskLevel riskLevelFromWire(String? value) => switch (value) {
      'BAJA' => RiskLevel.baja,
      'MODERADA' => RiskLevel.moderada,
      'ALTA' => RiskLevel.alta,
      'CRITICA' => RiskLevel.critica,
      _ => RiskLevel.moderada,
    };

/// De dónde sale una advertencia de correlación. Es parte del contrato y no un detalle interno:
/// una correlación medida sobre precios reales y una inferida de que dos activos comparten sector
/// tienen fuerza probatoria muy distinta, y la UI las muestra con chips distintos.
enum CorrelationBasis { priceHistory, sector }

/// `sector` como fallback: es la afirmación más débil de las dos, así que un valor desconocido
/// degrada la evidencia en vez de presentarla como medición.
CorrelationBasis correlationBasisFromWire(String? value) => switch (value) {
      'PRICE_HISTORY' => CorrelationBasis.priceHistory,
      _ => CorrelationBasis.sector,
    };

@immutable
class SectorAllocation {
  const SectorAllocation({
    required this.sector,
    required this.label,
    required this.weightPct,
    required this.tickerCount,
    required this.tickers,
  });

  factory SectorAllocation.fromJson(Map<String, dynamic> json) =>
      SectorAllocation(
        sector: sectorFromWire(json['sector'] as String?),
        // La etiqueta legible la manda el backend: si agrega un sector, la app vieja igual muestra
        // su nombre en castellano en vez de un código en mayúsculas.
        label: json['label'] as String? ?? '—',
        weightPct: (json['weight_pct'] as num?)?.toDouble() ?? 0,
        tickerCount: (json['ticker_count'] as num?)?.toInt() ?? 0,
        tickers: [
          for (final ticker in json['tickers'] as List? ?? []) ticker as String,
        ],
      );

  final PortfolioSector sector;
  final String label;
  final double weightPct;
  final int tickerCount;

  /// Qué activos concretos forman este sector. Viajan además del porcentaje porque un "40% en
  /// Tecnología" sin decir cuáles son no es accionable.
  final List<String> tickers;
}

@immutable
class ConcentrationRisk {
  const ConcentrationRisk({
    required this.level,
    required this.headline,
    required this.topSector,
    required this.topSectorLabel,
    required this.topSectorWeightPct,
    required this.distinctSectors,
    required this.herfindahlIndex,
    required this.notes,
  });

  factory ConcentrationRisk.fromJson(Map<String, dynamic> json) =>
      ConcentrationRisk(
        level: riskLevelFromWire(json['level'] as String?),
        headline: json['headline'] as String? ?? '',
        topSector: sectorFromWire(json['top_sector'] as String?),
        topSectorLabel: json['top_sector_label'] as String? ?? '—',
        topSectorWeightPct:
            (json['top_sector_weight_pct'] as num?)?.toDouble() ?? 0,
        distinctSectors: (json['distinct_sectors'] as num?)?.toInt() ?? 0,
        herfindahlIndex: (json['herfindahl_index'] as num?)?.toDouble() ?? 0,
        notes: [
          for (final note in json['notes'] as List? ?? []) note as String,
        ],
      );

  final RiskLevel level;

  /// Frase ya armada por el backend ("70% concentrado en Tecnología — riesgo alto"). Se muestra tal
  /// cual en vez de componerla acá para que diga lo mismo en la app, en el push y en la narrativa
  /// de la IA.
  final String headline;
  final PortfolioSector topSector;
  final String topSectorLabel;
  final double topSectorWeightPct;
  final int distinctSectors;

  /// Índice de Herfindahl normalizado a 0-1. Es lo que hace comparables dos carteras: "35% en
  /// Tech" dice poco si el resto está repartido en 8 sectores o en 2.
  final double herfindahlIndex;
  final List<String> notes;
}

@immutable
class CorrelationWarning {
  const CorrelationWarning({
    required this.tickers,
    required this.basis,
    required this.coefficient,
    required this.observations,
    required this.message,
  });

  factory CorrelationWarning.fromJson(Map<String, dynamic> json) =>
      CorrelationWarning(
        tickers: [
          for (final ticker in json['tickers'] as List? ?? []) ticker as String,
        ],
        basis: correlationBasisFromWire(json['basis'] as String?),
        coefficient: (json['coefficient'] as num?)?.toDouble(),
        observations: (json['observations'] as num?)?.toInt(),
        message: json['message'] as String? ?? '',
      );

  final List<String> tickers;
  final CorrelationBasis basis;

  /// `null` cuando la base es `sector`: el backend no inventa un número para una advertencia que no
  /// midió, y la UI no debe rellenarlo.
  final double? coefficient;
  final int? observations;
  final String message;

  bool get isMeasured => basis == CorrelationBasis.priceHistory;
}

@immutable
class DiversificationSuggestion {
  const DiversificationSuggestion({
    required this.sector,
    required this.label,
    required this.rationale,
  });

  factory DiversificationSuggestion.fromJson(Map<String, dynamic> json) =>
      DiversificationSuggestion(
        sector: sectorFromWire(json['sector'] as String?),
        label: json['label'] as String? ?? '—',
        rationale: json['rationale'] as String? ?? '',
      );

  final PortfolioSector sector;
  final String label;
  final String rationale;
}

@immutable
class PortfolioAudit {
  const PortfolioAudit({
    required this.generatedAt,
    required this.positionCount,
    required this.weightingBasis,
    required this.availability,
    required this.sectorAllocation,
    required this.sectorDataAvailable,
    required this.riskConcentration,
    required this.correlationWarnings,
    required this.correlationMeasured,
    required this.diversificationSuggestions,
    required this.aiSummary,
    required this.aiSummaryAvailable,
    required this.degradationReason,
    required this.servedFromCache,
  });

  factory PortfolioAudit.fromJson(Map<String, dynamic> json) => PortfolioAudit(
        generatedAt: DateTime.parse(json['generated_at'] as String),
        positionCount: (json['position_count'] as num?)?.toInt() ?? 0,
        weightingBasis:
            json['weighting_basis'] as String? ?? 'EQUAL_WEIGHT_BY_COUNT',
        availability: availabilityFromWire(json['availability'] as String?),
        sectorAllocation: [
          for (final entry in json['sector_allocation'] as List? ?? [])
            SectorAllocation.fromJson(entry as Map<String, dynamic>),
        ],
        sectorDataAvailable: json['sector_data_available'] as bool? ?? false,
        riskConcentration: json['risk_concentration'] == null
            ? null
            : ConcentrationRisk.fromJson(
                json['risk_concentration'] as Map<String, dynamic>,
              ),
        correlationWarnings: [
          for (final entry in json['correlation_warnings'] as List? ?? [])
            CorrelationWarning.fromJson(entry as Map<String, dynamic>),
        ],
        correlationMeasured: json['correlation_measured'] as bool? ?? false,
        diversificationSuggestions: [
          for (final entry
              in json['diversification_suggestions'] as List? ?? [])
            DiversificationSuggestion.fromJson(entry as Map<String, dynamic>),
        ],
        aiSummary: json['ai_summary'] as String?,
        aiSummaryAvailable: json['ai_summary_available'] as bool? ?? false,
        degradationReason: json['degradation_reason'] as String?,
        servedFromCache: json['served_from_cache'] as bool? ?? false,
      );

  final DateTime generatedAt;
  final int positionCount;

  /// Hoy siempre `EQUAL_WEIGHT_BY_COUNT`. Se guarda como string y no como enum porque el cliente no
  /// necesita ramificar sobre él —solo mostrar la aclaración correcta— y un enum obligaría a
  /// releasear la app el día que el backend agregue `MARKET_VALUE`.
  final String weightingBasis;
  final DataAvailability availability;
  final List<SectorAllocation> sectorAllocation;
  final bool sectorDataAvailable;
  final ConcentrationRisk? riskConcentration;
  final List<CorrelationWarning> correlationWarnings;

  /// `true` solo si al menos un PAR se pudo medir contra precios reales. Con `false`, la ausencia
  /// de advertencias no significa "los medimos y no correlacionan" sino "no los pudimos medir" — y
  /// la UI tiene que decir esa diferencia.
  final bool correlationMeasured;
  final List<DiversificationSuggestion> diversificationSuggestions;
  final String? aiSummary;
  final bool aiSummaryAvailable;
  final String? degradationReason;
  final bool servedFromCache;

  /// Sin activos no hay nada que auditar. Se distingue del resto de los estados degradados porque
  /// tiene una acción clara asociada ("agregá activos"), no un motivo técnico.
  bool get isEmpty => positionCount == 0;

  /// `true` cuando los pesos son cantidad de activos y no dinero invertido. Es lo que gobierna el
  /// texto de la aclaración; el día que el backend soporte posiciones reales, este getter devuelve
  /// `false` y la UI deja de aclararlo sin más cambios.
  bool get isEqualWeighted => weightingBasis == 'EQUAL_WEIGHT_BY_COUNT';
}
