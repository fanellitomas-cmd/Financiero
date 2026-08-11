import 'package:intl/intl.dart';

import '../../corporate/data/corporate_formatting.dart';
import '../../lab/data/note.dart';
import 'ai_lab_models.dart';

/// Convierte un diagnóstico contable o una simulación en Markdown para guardarlo en el Lab.
///
/// Todo lo que sale de acá son datos que ya están en pantalla, transcriptos. La única prosa generada
/// por IA que puede aparecer es la lectura que el backend ya devolvió, y se copia **con su
/// advertencia de origen pegada**: dentro de una nota, seis meses después, un párrafo bien escrito
/// sin esa marca se lee como una conclusión propia.
///
/// Se reutiliza el formateo del Hub Corporativo (`corporate_formatting.dart`) en vez de tener uno
/// propio: los dos módulos muestran los mismos montos y márgenes de las mismas empresas, y dos
/// formatos distintos para "US$ 46,10 MM" harían que la misma cifra se vea de dos maneras según la
/// pantalla desde la que se guardó.

const String kAnalysisSnippetHeading = 'Diagnóstico contable';
const String kScenarioSnippetHeading = 'Simulación de escenario';

String _savedAtLine([DateTime? now]) {
  final stamp = DateFormat('dd/MM/yyyy HH:mm').format(now ?? DateTime.now());
  return '_Guardado desde el Laboratorio Financiero el $stamp._';
}

/// La advertencia que acompaña a la prosa del modelo. Va DENTRO de la nota, no solo en la UI.
const String _narrativeDisclaimer =
    '_Lectura redactada por IA sobre los números calculados arriba. Los números salen de fórmulas '
    'en el backend; el texto es una interpretación, no una recomendación de inversión._';

/// Un NIVEL en porcentaje: un margen, un ROE, una tasa. Sin signo adelante.
///
/// La distinción con [_change] no es cosmética: un margen de 63,9% escrito "+63,9%" se lee como
/// "63,9 puntos MÁS de margen", que es otro dato. La nota se relee semanas después y sin la pantalla
/// al lado, así que el texto tiene que aguantar solo.
String _level(double? value) => value == null
    ? kMissingValue
    : formatSurprisePct(value).replaceAll('+', '').replaceAll('−', '-');

/// Una VARIACIÓN en porcentaje: acá el signo es parte del dato y se conserva.
String _change(double? value) =>
    value == null ? kMissingValue : formatSurprisePct(value);

String _multiple(double? value) =>
    value == null ? kMissingValue : '${formatEps(value)}x';

// --- Diagnóstico contable ------------------------------------------------------------------------

/// El diagnóstico completo: márgenes, DuPont, banderas y la lectura.
String buildAnalysisNoteMarkdown(
  FinancialAnalysisResponse analysis, {
  DateTime? now,
}) {
  final lines = <String>[];
  final income = analysis.latestIncome;
  final balance = analysis.latestBalance;
  final cash = analysis.latestCashFlow;

  lines.add('## $kAnalysisSnippetHeading — ${analysis.ticker}');
  lines.add('');
  lines.add(_savedAtLine(now));
  lines.add('');
  if (analysis.companyName != null) {
    lines.add('- Empresa: ${analysis.companyName}');
  }
  lines.add('- Periodicidad: ${statementPeriodLabel(analysis.period)}');
  if (income != null) {
    lines.add('- Último período: ${income.label}');
  }
  lines.add('');

  if (!analysis.hasStatements) {
    lines.add(
      '> Sin estados contables al momento de tomar esta nota'
      '${analysis.degradationReason == null ? "" : ": ${analysis.degradationReason}"}.',
    );
    return lines.join('\n');
  }

  if (income != null) {
    lines.add('### Resultados');
    lines.add('');
    lines.add('- Ingresos: `${formatRevenue(income.revenue)}`');
    lines.add('- Margen bruto: `${_level(income.grossMarginPct)}`');
    lines.add('- Margen operativo: `${_level(income.operatingMarginPct)}`');
    lines.add(
      '- Margen EBITDA: `${_level(income.ebitdaMarginPct)}`'
      '${income.ebitdaIsDerived ? " _(EBITDA reconstruido como operativo + amortizaciones)_" : ""}',
    );
    lines.add('- Margen neto: `${_level(income.netMarginPct)}`');
    lines.add('- EPS diluido: `${formatEps(income.epsDiluted)}`');
    lines.add('');
  }

  if (balance != null) {
    lines.add('### Balance');
    lines.add('');
    lines.add('- Activo: `${formatRevenue(balance.totalAssets)}`');
    lines.add('- Pasivo: `${formatRevenue(balance.totalLiabilities)}`');
    lines.add('- Patrimonio: `${formatRevenue(balance.totalEquity)}`');
    lines.add('- Deuda total: `${formatRevenue(balance.totalDebt)}`');
    lines.add(
      '- Deuda neta: `${formatRevenue(balance.netDebt)}`'
      '${balance.hasNetCash ? " _(caja neta positiva)_" : ""}',
    );
    lines.add('- Liquidez corriente: `${_multiple(balance.currentRatio)}`');
    lines.add('- Deuda/Patrimonio: `${_multiple(balance.debtToEquity)}`');
    lines.add('');
  }

  if (cash != null) {
    lines.add('### Caja');
    lines.add('');
    lines.add('- Caja operativa: `${formatRevenue(cash.operatingCashFlow)}`');
    lines.add('- Capex: `${formatRevenue(cash.capitalExpenditure)}`');
    lines.add('- Flujo de caja libre: `${formatRevenue(cash.freeCashFlow)}`');
    lines.add(
      '- Conversión FCF/resultado neto: `${_level(cash.fcfConversionPct)}`',
    );
    lines.add('');
  }

  final dupont = analysis.dupont;
  if (dupont.isComplete) {
    lines.add('### DuPont');
    lines.add('');
    lines.add(
      '`ROE ${_level(dupont.roePct)}` = margen neto `${_level(dupont.netMarginPct)}` × '
      'rotación `${_multiple(dupont.assetTurnover)}` × '
      'apalancamiento `${_multiple(dupont.equityMultiplier)}`',
    );
    final driver = dupont.dominantDriver;
    if (driver != null) {
      // La lectura del DuPont es de dónde VIENE el ROE: sin esta línea, la nota guarda tres números
      // y pierde justamente lo que la descomposición aporta.
      lines.add('');
      lines.add('El factor que más pesa es **${dupontDriverLabel(driver)}**.');
    }
    lines.add('');
  }

  if (analysis.flags.isNotEmpty) {
    lines.add('### Banderas');
    lines.add('');
    for (final flag in analysis.flags) {
      final mark = flag.kind == FlagKind.red ? '🔴' : '🟢';
      lines.add('- $mark **${flag.title}** — ${flag.detail}');
    }
    lines.add('');
    lines.add('_${criteriaSourceCaption(analysis.dupont.criteriaSource)}_');
    lines.add('');
  }

  final narrative = analysis.narrative;
  if (narrative != null && narrative.trim().isNotEmpty) {
    lines.add('### Lectura');
    lines.add('');
    lines.add(narrative.trim());
    lines.add('');
    lines.add(_narrativeDisclaimer);
  } else if (analysis.narrativeDegradationReason != null) {
    lines.add(
      '> Sin lectura escrita: ${analysis.narrativeDegradationReason}',
    );
  }

  return lines.join('\n');
}

/// El hilo de la conversación, para guardar las preguntas y respuestas tal como pasaron.
String buildConversationNoteMarkdown(
  FinancialAnalysisResponse analysis, {
  DateTime? now,
}) {
  final lines = <String>[
    '## Consulta contable — ${analysis.ticker}',
    '',
    _savedAtLine(now),
    '',
  ];

  if (analysis.history.isEmpty) {
    lines.add('> Todavía no hay preguntas en este hilo.');
    return lines.join('\n');
  }

  for (final turn in analysis.history) {
    lines.add(turn.isUser ? '**Pregunta:** ${turn.content}' : turn.content);
    lines.add('');
  }

  lines.add('---');
  lines.add('');
  lines.add(_narrativeDisclaimer);
  return lines.join('\n');
}

// --- Simulación ----------------------------------------------------------------------------------

/// Una palanca del escenario, o la constancia de que quedó sin fijar.
///
/// `signed` distingue las palancas que expresan una variación (crecimiento, inflación) de las que
/// fijan un nivel (margen, tasa): mismo criterio que en la pantalla, porque la nota se lee sola.
String _leverLine(
  String label,
  double? value, {
  String unit = '%',
  bool signed = true,
}) =>
    value == null
        ? '- $label: _sin fijar_'
        : '- $label: `${signed ? _change(value) : _level(value)}`'
            .replaceAll('%', unit);

/// La simulación completa: base, variables, proyección, matriz y supuestos.
String buildScenarioNoteMarkdown(
  ScenarioSimulationResult result, {
  DateTime? now,
}) {
  final lines = <String>[];
  final baseline = result.baseline;
  final projection = result.projection;
  final variables = result.appliedVariables;

  lines.add('## $kScenarioSnippetHeading — ${result.ticker}');
  lines.add('');
  lines.add(_savedAtLine(now));
  lines.add('');

  if (result.availability == DataAvailability.unavailable) {
    lines.add(
      '> No se pudo simular al momento de tomar esta nota'
      '${result.degradationReason == null ? "" : ": ${result.degradationReason}"}.',
    );
    return lines.join('\n');
  }

  lines.add('### Punto de partida');
  lines.add('');
  lines.add(
    '- Período base: ${baseline.periodLabel ?? formatCorporateDate(baseline.periodEnd)}',
  );
  lines.add('- Ingresos: `${formatRevenue(baseline.revenue)}`');
  lines.add(
    '- EBITDA: `${formatRevenue(baseline.ebitda)}` '
    '(margen `${_level(baseline.ebitdaMarginPct)}`)',
  );
  lines.add('- EPS reportado: `${formatEps(baseline.eps)}`');
  if (baseline.modelEpsDiffers) {
    // Los dos EPS y por qué difieren: sin esto, la variación de la simulación parece medida contra el
    // número que la empresa publicó, y no lo está.
    lines.add(
      '- EPS del punto cero del modelo: `${formatEps(baseline.modelEps)}` '
      '_(la cascada no reproduce los resultados no operativos; las variaciones se miden contra este)_',
    );
  }
  lines.add('- Precio de referencia: `${formatEps(baseline.referencePrice)}`');
  lines.add('');

  lines.add('### Variables del escenario');
  lines.add('');
  lines.add(_leverLine('Crecimiento de ingresos', variables.revenueGrowthPct));
  lines.add(
    _leverLine('Margen EBITDA', variables.ebitdaMarginPct, signed: false),
  );
  lines.add(
    _leverLine('Tasa de interés', variables.interestRatePct, signed: false),
  );
  lines.add(_leverLine('Inflación', variables.inflationPct));
  lines.add('');

  if (result.customEvent != null) {
    lines.add('**Evento descrito:** ${result.customEvent}');
    lines.add('');
    if (result.customEventIsQualitative) {
      lines.add(
        '> Este evento **no está cuantificado**: no movió ninguno de los números de abajo. '
        'Cuantificarlo habría requerido inventar un coeficiente.',
      );
      lines.add('');
    }
  }

  lines.add('### Proyección');
  lines.add('');
  lines.add(
    '- Ingresos: `${formatRevenue(projection.revenue)}` '
    '(`${_change(projection.revenueChangePct)}`)',
  );
  lines.add(
    '- EBITDA: `${formatRevenue(projection.ebitda)}` '
    '(`${_change(projection.ebitdaChangePct)}`)',
  );
  lines.add(
    '- EPS: `${formatEps(projection.eps)}` (`${_change(projection.epsChangePct)}`)',
  );
  lines.add(
    '- FCF: `${formatRevenue(projection.freeCashFlow)}` '
    '(`${_change(projection.freeCashFlowChangePct)}`)',
  );
  if (projection.impliedPrice != null) {
    lines.add(
      '- Precio implícito: `${formatEps(projection.impliedPrice)}` '
      '(`${_change(projection.impliedPriceChangePct)}`)',
    );
  }
  lines.add('');

  if (result.valuationNote != null) {
    lines.add('_${result.valuationNote}_');
    lines.add('');
  }

  if (result.sensitivity.isNotEmpty) {
    lines.add('### Matriz de sensibilidad');
    lines.add('');
    for (final item in result.sensitivity) {
      lines.add(
        '- **${item.label}**: EPS `${formatEps(item.projection.eps)}` '
        '(`${_change(item.projection.epsChangePct)}`)'
        '${item.projection.impliedPrice == null ? "" : ", precio `${formatEps(item.projection.impliedPrice)}`"}',
      );
    }
    lines.add('');
  }

  if (result.modelAssumptions.isNotEmpty) {
    // Los supuestos se copian ENTEROS: una proyección guardada sin ellos tiene la autoridad de un
    // pronóstico y la solidez de una cuenta al margen.
    lines.add('### Supuestos del modelo');
    lines.add('');
    for (final assumption in result.modelAssumptions) {
      lines.add('- $assumption');
    }
    lines.add('');
  }

  final narrative = result.narrative;
  if (narrative != null && narrative.trim().isNotEmpty) {
    lines.add('### Lectura');
    lines.add('');
    lines.add(narrative.trim());
    lines.add('');
    lines.add(_narrativeDisclaimer);
  }

  return lines.join('\n');
}

// --- Borradores ----------------------------------------------------------------------------------

NoteDraft analysisNoteDraft(
  FinancialAnalysisResponse analysis, {
  String? folderId,
  DateTime? now,
}) {
  final period = analysis.latestIncome?.label;
  return NoteDraft.blank(
    folderId: folderId,
    ticker: analysis.ticker,
    title: '${analysis.ticker} — Diagnóstico contable'
        '${period == null ? "" : " ($period)"}',
    content: buildAnalysisNoteMarkdown(analysis, now: now),
  );
}

NoteDraft conversationNoteDraft(
  FinancialAnalysisResponse analysis, {
  String? folderId,
  DateTime? now,
}) =>
    NoteDraft.blank(
      folderId: folderId,
      ticker: analysis.ticker,
      title: '${analysis.ticker} — Consulta contable',
      content: buildConversationNoteMarkdown(analysis, now: now),
    );

/// Borrador de la simulación.
///
/// El título lleva la palanca dominante y no la fecha: dos simulaciones del mismo activo se
/// distinguen por lo que se movió, no por cuándo se guardaron.
NoteDraft scenarioNoteDraft(
  ScenarioSimulationResult result, {
  String? folderId,
  DateTime? now,
}) {
  final variables = result.appliedVariables;
  final descriptor = switch (variables) {
    ScenarioVariables(revenueGrowthPct: final growth?) =>
      'crecimiento ${formatSurprisePct(growth)}',
    ScenarioVariables(ebitdaMarginPct: final margin?) =>
      'margen ${formatSurprisePct(margin).replaceAll("+", "")}',
    ScenarioVariables(interestRatePct: final rate?) =>
      'tasa ${formatSurprisePct(rate).replaceAll("+", "")}',
    ScenarioVariables(inflationPct: final inflation?) =>
      'inflación ${formatSurprisePct(inflation).replaceAll("+", "")}',
    _ => 'solo evento',
  };

  return NoteDraft.blank(
    folderId: folderId,
    ticker: result.ticker,
    title: '${result.ticker} — Escenario: $descriptor',
    content: buildScenarioNoteMarkdown(result, now: now),
  );
}
