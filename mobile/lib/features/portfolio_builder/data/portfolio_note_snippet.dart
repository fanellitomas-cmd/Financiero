import 'package:intl/intl.dart';

import '../../corporate/data/corporate_formatting.dart';
import '../../lab/data/note.dart';
import 'portfolio_builder_models.dart';
import 'portfolio_formatting.dart';

/// Convierte una simulación de cartera en Markdown para congelarla en el Lab.
///
/// Todo lo que sale de acá ya está en pantalla, transcripto. Lo que la nota agrega es el CONTEXTO
/// que la pantalla tiene implícito y el papel no: qué precios eran esperados y cuáles de mercado, con
/// qué cobertura se midió el retorno, y sobre qué base se ponderaron los sectores.
///
/// Sin eso, una nota que dice "Tecnología 80% — riesgo crítico" leída seis meses después no se puede
/// auditar: no se sabe si ese 80% era de capital o de cantidad de símbolos, ni si los precios eran
/// reales o supuestos.

const String kPortfolioSnippetHeading = 'Simulación de cartera';

String _savedAtLine([DateTime? now]) {
  final stamp = DateFormat('dd/MM/yyyy HH:mm').format(now ?? DateTime.now());
  return '_Guardado desde el Constructor de Portafolios el $stamp._';
}

/// Un NIVEL en porcentaje, sin signo: un peso de cartera de 40% escrito "+40%" se leería como "40
/// puntos más que antes", que es otra afirmación. Mismo criterio que el Laboratorio Financiero.
String _level(double? value) => value == null
    ? kMissingValue
    : formatSurprisePct(value).replaceAll('+', '').replaceAll('−', '-');

/// Una VARIACIÓN: acá el signo es parte del dato.
String _change(double? value) =>
    value == null ? kMissingValue : formatSurprisePct(value);

String buildPortfolioNoteMarkdown(
  PortfolioSimulationResult result, {
  DateTime? now,
}) {
  final lines = <String>[
    '## $kPortfolioSnippetHeading',
    '',
    _savedAtLine(now),
    '',
    '- Presupuesto: `${formatUsd(result.totalBudget)}`',
    '- Asignado: `${formatUsd(result.allocatedAmount)}`',
  ];

  final over = result.overBudgetAmount;
  if (over != null) {
    lines.add(
      '- **Excedente sobre el presupuesto: `${formatUsd(over)}`** — no se recortó ninguna '
      'posición.',
    );
  } else {
    lines.add(
      '- Efectivo sin asignar: `${formatUsd(result.cashUnallocated)}` '
      '(`${_level(result.cashPct)}`)',
    );
  }
  lines.add('');

  if (!result.hasAllocation) {
    lines.add(
      '> Ninguna posición quedó con capital asignado'
      '${result.degradationReason == null ? "" : ": ${result.degradationReason}"}.',
    );
    return lines.join('\n');
  }

  lines
    ..add('### Posiciones')
    ..add('')
    ..add('| Activo | Precio | Unidades | Invertido | Peso | 1 año |')
    ..add('| --- | --- | --- | --- | --- | --- |');

  for (final item in result.funded) {
    // El origen del precio va PEGADO al número, no en una leyenda aparte: quien relea la tabla tiene
    // que poder distinguir de un vistazo qué posiciones eran un supuesto suyo.
    final price = item.isCustomPrice
        ? '${formatUsd(item.effectivePrice)} (esperado)'
        : formatUsd(item.effectivePrice);
    lines.add(
      '| ${item.ticker} | `$price` | `${item.units}` | '
      '`${formatUsd(item.investedAmount)}` | `${_level(item.percentageOfTotal)}` | '
      '`${_change(item.return1yPct)}` |',
    );
  }
  lines.add('');

  final unfunded = result.unfunded;
  if (unfunded.isNotEmpty) {
    lines
      ..add('### Sin capital asignado')
      ..add('');
    for (final item in unfunded) {
      lines.add('- ${item.ticker}: ${item.note ?? "sin motivo declarado"}');
    }
    lines.add('');
  }

  lines
    ..add('### Distribución por sector')
    ..add('')
    ..add(
      '_Ponderada por capital invertido '
      '(`${result.weightingBasis == WeightingBasis.marketValue ? "MARKET_VALUE" : "EQUAL_WEIGHT_BY_COUNT"}`), '
      'no por cantidad de símbolos._',
    )
    ..add('');
  for (final sector in result.sectorAllocation) {
    lines.add(
      '- ${sector.label}: `${formatUsd(sector.amount)}` '
      '(`${_level(sector.percentageOfTotal)}`, ${sector.tickerCount} '
      '${sector.tickerCount == 1 ? "activo" : "activos"})',
    );
  }
  lines.add('');

  final risk = result.riskScore;
  if (risk != null) {
    lines
      ..add('### Concentración')
      ..add('')
      ..add(
        // "Concentración alta" y no "Riesgo alta": las etiquetas del nivel son femeninas (Baja,
        // Moderada, Alta, Crítica) y concuerdan con "concentración", no con "riesgo". Es además la
        // misma frase que muestra el badge en pantalla.
        '**Concentración ${riskLevelLabel(risk).toLowerCase()}** — '
        'Herfindahl `${formatHerfindahl(result.herfindahlIndex, decimals: 4)}`, '
        'sector dominante `${_level(result.topSectorWeightPct)}`.',
      )
      ..add('');
    for (final note in result.riskNotes) {
      lines.add('- $note');
    }
    lines
      ..add('')
      ..add(
        '_El nivel sale de umbrales fijos en código sobre el peso del sector dominante y el índice '
        'de Herfindahl, tomando el peor de los dos. Es la misma escala que usa la Auditoría de '
        'Portafolio._',
      )
      ..add('');
  }

  lines
    ..add('### Retorno del último año')
    ..add('');
  if (result.portfolioReturn1yPct == null) {
    lines.add(
      '- No se pudo medir: ninguna posición tenía histórico suficiente.',
    );
  } else {
    lines.add(
      '- Ponderado por capital: `${_change(result.portfolioReturn1yPct)}`',
    );
    lines.add(
      '- Medido sobre el `${_level(result.returnCoveragePct)}` del capital asignado'
      '${result.returnIsComplete ? "" : " — el resto no tenía histórico y NO se contó como 0%"}.',
    );
  }
  lines.add('');

  if (result.notes.isNotEmpty) {
    lines
      ..add('### Supuestos del cálculo')
      ..add('');
    for (final note in result.notes) {
      lines.add('- $note');
    }
    lines.add('');
  }

  lines.add(
    '_Es una simulación, no una cartera real: no hay órdenes, comisiones ni impuestos, y los '
    'retornos son históricos, no proyecciones._',
  );
  return lines.join('\n');
}

/// El borrador de la nota.
///
/// El título describe el TAMAÑO y la CONCENTRACIÓN, no la fecha: dos simulaciones del mismo día se
/// distinguen por cómo repartieron, no por cuándo se guardaron.
NoteDraft portfolioNoteDraft(
  PortfolioSimulationResult result, {
  String? folderId,
  DateTime? now,
}) {
  final positions = result.funded.length;
  final top = result.sectorAllocation.isEmpty
      ? null
      : result.sectorAllocation.first;
  final descriptor = top == null
      ? 'sin asignar'
      : '${top.label} ${_level(top.percentageOfTotal)}';

  return NoteDraft.blank(
    folderId: folderId,
    title: 'Cartera ${formatUsd(result.totalBudget)} · '
        '$positions ${positions == 1 ? "activo" : "activos"} · $descriptor',
    content: buildPortfolioNoteMarkdown(result, now: now),
  );
}
