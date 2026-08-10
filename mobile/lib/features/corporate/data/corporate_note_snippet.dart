import 'package:intl/intl.dart';

import '../../lab/data/note.dart';
import 'corporate_formatting.dart';
import 'corporate_models.dart';

/// Convierte lo que muestra el Hub Corporativo en Markdown para guardarlo en una nota del Lab.
///
/// Todo lo que sale de acá son datos que ya están en pantalla, transcriptos: **no se le pide al
/// modelo que redacte nada**. La única prosa generada por IA que puede aparecer es la síntesis de un
/// reporte SEC, que ya venía escrita en la respuesta y se copia con su advertencia pegada.
///
/// Dos decisiones que valen para los cuatro bloques:
///
///   - **Se escribe la fecha en que se guardó.** Un balance estimado y una noticia son ciertos en un
///     momento; leídos dentro de seis meses en una nota sin fecha se confunden con el presente.
///   - **Lo que falta se declara.** Un EPS que el proveedor no trajo se escribe `—` con su nota al
///     pie, no se omite: una nota que copió solo lo que había se lee después como si eso fuera todo
///     lo que se sabía.

/// Encabezados de cada tipo de bloque. Se conservan textuales dentro de la nota para que, al
/// reencontrarla, sea obvio qué parte se pegó del Hub y qué parte escribió el usuario.
const String kEarningsSnippetHeading = 'Balance';
const String kEarningsHistorySnippetHeading = 'Histórico de sorpresas';
const String kFilingSnippetHeading = 'Reporte SEC';
const String kNewsSnippetHeading = 'Noticia corporativa';

String _savedAtLine([DateTime? now]) {
  final stamp = DateFormat('dd/MM/yyyy HH:mm').format(now ?? DateTime.now());
  return '_Guardado desde el Hub Corporativo el $stamp._';
}

/// La advertencia que acompaña a toda etiqueta heurística. Va DENTRO de la nota y no solo en la UI:
/// la nota es lo que se relee, y sin esto un "BAJISTA" copiado se lee mañana como un veredicto.
String _classificationDisclaimer(ClassificationSource source) =>
    '_${classificationSourceCaption(source)}_';

// --- Balances ------------------------------------------------------------------------------------

/// Un balance, programado o publicado.
String buildEarningsNoteMarkdown(EarningsEvent event, {DateTime? now}) {
  final lines = <String>[];
  final name = event.companyName;
  final period = formatFiscalPeriod(event);

  lines.add('## $kEarningsSnippetHeading — ${event.ticker}');
  lines.add('');
  lines.add(_savedAtLine(now));
  lines.add('');
  if (name != null && name.isNotEmpty) {
    lines.add('- Empresa: $name');
  }
  lines.add(
    '- Fecha del reporte: **${formatCorporateDate(event.eventDate)}** '
    '(${earningsSessionLabel(event.session)})',
  );
  if (period != null) {
    lines.add('- Período: $period');
  }
  lines.add(
    '- Estado: ${event.status == EarningsStatus.reported ? "Reportado" : "Programado"}',
  );
  lines.add('');

  lines.add('### EPS');
  lines.add('');
  lines.add('- Estimado: `${formatEps(event.epsEstimated)}`');
  lines.add('- Reportado: `${formatEps(event.epsActual)}`');
  if (event.epsSurprise != null) {
    // La diferencia absoluta va siempre que exista; el porcentaje solo cuando el backend lo calculó.
    lines.add(
      '- Sorpresa: `${formatEpsDelta(event.epsSurprise)}`'
      '${event.epsSurprisePct == null ? "" : " (${formatSurprisePct(event.epsSurprisePct)})"}'
      ' — **${surpriseDirectionLabel(event.surpriseDirection)}**',
    );
    if (event.epsSurprisePct == null) {
      lines.add(
        '- _Sin porcentaje de sorpresa: el estimado estaba demasiado cerca de cero para que el '
        'cociente signifique algo._',
      );
    }
  }
  lines.add('');

  if (event.revenueEstimated != null || event.revenueActual != null) {
    lines.add('### Ingresos');
    lines.add('');
    lines.add('- Estimado: `${formatRevenue(event.revenueEstimated)}`');
    lines.add('- Reportado: `${formatRevenue(event.revenueActual)}`');
    if (event.revenueSurprise != null) {
      lines.add(
        '- Sorpresa: `${formatRevenue(event.revenueSurprise)}`'
        '${event.revenueSurprisePct == null ? "" : " (${formatSurprisePct(event.revenueSurprisePct)})"}',
      );
    }
    lines.add('');
  }

  lines.add('---');
  lines.add('');
  lines.add(
    '_Datos del proveedor de fundamentales. Las estimaciones son de analistas, no de la empresa._',
  );

  return lines.join('\n');
}

/// El histórico de sorpresas completo, con su estadística.
String buildEarningsHistoryNoteMarkdown(EarningsHistory history, {DateTime? now}) {
  final lines = <String>[];

  lines.add('## $kEarningsHistorySnippetHeading — ${history.ticker}');
  lines.add('');
  lines.add(_savedAtLine(now));
  lines.add('');

  if (history.quarters.isEmpty) {
    lines.add(
      '> Sin trimestres publicados disponibles al momento de tomar esta nota'
      '${history.degradationReason == null ? "" : ": ${history.degradationReason}"}.',
    );
    return lines.join('\n');
  }

  lines.add(
    '- Aciertos: **${history.beatCount}** de ${history.measuredQuarters} trimestres medidos'
    '${history.beatRate == null ? "" : " (${formatRate(history.beatRate)})"}',
  );
  lines.add('- Fallos: ${history.missCount} · En línea: ${history.inLineCount}');
  if (history.averageSurprisePct != null) {
    lines.add(
      '- Sorpresa promedio: `${formatSurprisePct(history.averageSurprisePct)}`',
    );
  }
  if (history.unmeasuredQuarters > 0) {
    // Se explica el denominador: sin esto, "2 de 3" sobre una lista de 4 filas parece un error.
    lines.add(
      '- _${history.unmeasuredQuarters} trimestre(s) llegaron sin estimación previa y no entran '
      'en la tasa: no se pueden contar ni como acierto ni como fallo._',
    );
  }
  lines.add('');

  // Una viñeta por trimestre y NO una tabla Markdown: el visor de notas de la app no renderiza
  // tablas (ver `markdown_view.dart`), así que una tabla quedaría como una fila de pipes literales
  // dentro de la nota. El dato importa más que la grilla.
  lines.add('### Trimestres');
  lines.add('');
  for (final quarter in history.quarters) {
    lines.add(
      '- **${formatCorporateDate(quarter.eventDate)}** — '
      'estimado `${formatEps(quarter.epsEstimated)}`, '
      'reportado `${formatEps(quarter.epsActual)}`, '
      'sorpresa `${formatEpsDelta(quarter.epsSurprise)}`'
      '${quarter.epsSurprisePct == null ? "" : " (${formatSurprisePct(quarter.epsSurprisePct)})"}'
      ' → ${surpriseDirectionLabel(quarter.surpriseDirection)}',
    );
  }

  return lines.join('\n');
}

// --- Reportes SEC --------------------------------------------------------------------------------

String buildFilingNoteMarkdown(SecFiling filing, {DateTime? now}) {
  final lines = <String>[];

  lines.add('## $kFilingSnippetHeading ${filing.displayType} — ${filing.ticker}');
  lines.add('');
  lines.add(_savedAtLine(now));
  lines.add('');
  lines.add('- Presentado: **${formatCorporateDate(filing.filedAt)}**');
  lines.add('- Tipo: ${filing.displayType} — ${filingTypeDescription(filing.filingType)}');
  final url = filing.bestUrl;
  if (url != null) {
    // El enlace oficial es lo más valioso del bloque: es lo único que permite ir a la fuente en vez
    // de confiar en el resumen. Se escribe pelado, sin `<>` ni sintaxis de link: el visor de notas
    // no renderiza links, y los delimitadores quedarían como caracteres sueltos alrededor de la URL.
    lines.add('- Documento oficial: $url');
  }
  lines.add('');

  if (filing.summaryAvailable && filing.summary != null) {
    lines.add('### Síntesis');
    lines.add('');
    lines.add(filing.summary!);
    lines.add('');
    lines.add(
      '_Síntesis generada por IA sobre los METADATOS del reporte (tipo y fecha): el sistema no '
      'descargó el documento. Sirve como guía de qué buscar adentro, no como resumen de lo que dice._',
    );
  } else {
    lines.add(
      '> Sin síntesis: el enlace oficial de arriba es la fuente. '
      '(Se puede pedir la síntesis desde el Hub Corporativo.)',
    );
  }

  return lines.join('\n');
}

// --- Noticias ------------------------------------------------------------------------------------

String buildNewsNoteMarkdown(CorporateNewsItem item, {DateTime? now}) {
  final lines = <String>[];

  lines.add('## $kNewsSnippetHeading — ${item.title}');
  lines.add('');
  lines.add(_savedAtLine(now));
  lines.add('');
  lines.add('- Fuente: ${item.source ?? kMissingValue}');
  lines.add('- Publicada: ${formatCorporateDate(item.publishedAt)}');
  lines.add(
    '- Clasificación: **${newsCategoryLabel(item.category)}** · '
    '**${newsSentimentLabel(item.sentiment)}**',
  );
  if (item.tickers.isNotEmpty) {
    lines.add('- Símbolos: ${item.tickers.join(", ")}');
  }
  final url = item.url;
  if (url != null) {
    lines.add('- Enlace: $url');
  }
  lines.add('');

  final summary = item.summary;
  if (summary != null && summary.trim().isNotEmpty) {
    lines.add(summary.trim());
    lines.add('');
  }

  lines.add('---');
  lines.add('');
  lines.add(_classificationDisclaimer(item.classificationSource));

  return lines.join('\n');
}

// --- Borradores ----------------------------------------------------------------------------------

/// Borrador de una nota nueva con el balance ya pegado.
///
/// El título lleva la fecha del reporte y no la de hoy: dos notas del mismo balance guardadas en
/// días distintos tienen que quedar como una sola cosa reconocible en el explorador.
NoteDraft earningsNoteDraft(
  EarningsEvent event, {
  String? folderId,
  DateTime? now,
}) =>
    NoteDraft.blank(
      folderId: folderId,
      ticker: event.ticker,
      title:
          '${event.ticker} — Balance del ${formatCorporateDate(event.eventDate)}',
      content: buildEarningsNoteMarkdown(event, now: now),
    );

NoteDraft earningsHistoryNoteDraft(
  EarningsHistory history, {
  String? folderId,
  DateTime? now,
}) =>
    NoteDraft.blank(
      folderId: folderId,
      ticker: history.ticker,
      title: '${history.ticker} — Histórico de sorpresas',
      content: buildEarningsHistoryNoteMarkdown(history, now: now),
    );

NoteDraft filingNoteDraft(
  SecFiling filing, {
  String? folderId,
  DateTime? now,
}) =>
    NoteDraft.blank(
      folderId: folderId,
      ticker: filing.ticker,
      title: '${filing.ticker} — ${filing.displayType} '
          '${formatCorporateDate(filing.filedAt)}',
      content: buildFilingNoteMarkdown(filing, now: now),
    );

/// Borrador de una nota nueva con la noticia pegada.
///
/// El ticker sale de la lista de símbolos del ítem, si trae alguno: así la nota aparece después en la
/// pestaña "Notas" de la ficha de ese activo, que es donde el usuario la va a buscar. Una noticia de
/// mercado sin símbolo queda sin vincular en vez de atribuírsela a uno al azar.
NoteDraft newsNoteDraft(
  CorporateNewsItem item, {
  String? folderId,
  String? ticker,
  DateTime? now,
}) =>
    NoteDraft.blank(
      folderId: folderId,
      ticker: ticker ?? (item.tickers.isEmpty ? null : item.tickers.first),
      title: _truncateTitle(item.title),
      content: buildNewsNoteMarkdown(item, now: now),
    );

/// El título de una nota tiene tope en el backend (200) y un titular largo lo pasa. Se corta con
/// puntos suspensivos en vez de dejar que el POST devuelva un 422 que el usuario no puede arreglar.
String _truncateTitle(String raw, {int maxLength = 120}) {
  final trimmed = raw.trim();
  if (trimmed.length <= maxLength) return trimmed;
  return '${trimmed.substring(0, maxLength - 1).trimRight()}…';
}

/// Agrega un bloque al final de una nota que ya existe.
///
/// Se **agrega** y nunca reemplaza: el cuerpo actual puede ser la tesis que el usuario escribió a
/// mano, y sobreescribirla con datos que se pueden volver a pedir sería la peor pérdida posible acá.
String appendCorporateSnippet(String existingContent, String snippet) {
  final trimmed = existingContent.trimRight();
  if (trimmed.isEmpty) return snippet;
  return '$trimmed\n\n$snippet';
}
