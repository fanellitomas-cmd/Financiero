import 'package:intl/intl.dart';

import '../../lab/data/note.dart';
import 'deep_intelligence.dart';

/// Convierte la Ficha de Inteligencia Profunda en Markdown para pegarlo en una nota del Lab.
///
/// Se compone en código y NO se le pide al modelo que lo redacte: todo lo que sale de acá son datos
/// que ya están en la Ficha, transcriptos textualmente. Pedirle un resumen del resumen agregaría una
/// segunda pasada del LLM sobre un texto que él mismo escribió, con una oportunidad más de inventar
/// un número que nadie midió.
///
/// Lo que falta se **declara**, no se omite: si los fundamentales no estaban disponibles, la nota lo
/// dice. Una nota que copia solo lo que había se lee, seis meses después, como si eso fuera todo lo
/// que se sabía del activo.

/// Encabezado que identifica al bloque insertado. Se conserva textual en la nota para que, al
/// reencontrarla, sea obvio qué parte la escribió el usuario y qué parte se pegó de la Ficha.
const String kIntelligenceSnippetHeading = 'Ficha de Inteligencia Profunda';

String _healthLabel(FinancialHealth health) => switch (health) {
      FinancialHealth.solida => 'Sólida',
      FinancialHealth.adecuada => 'Adecuada',
      FinancialHealth.ajustada => 'Ajustada',
      FinancialHealth.debil => 'Débil',
      FinancialHealth.indeterminada => 'Indeterminada',
    };

String _trendLabel(TrendDirection trend) => switch (trend) {
      TrendDirection.alcista => 'Alcista',
      TrendDirection.lateral => 'Lateral',
      TrendDirection.bajista => 'Bajista',
    };

String _confidenceLabel(ConfidenceLevel confidence) => switch (confidence) {
      ConfidenceLevel.alta => 'alta',
      ConfidenceLevel.media => 'media',
      ConfidenceLevel.baja => 'baja',
    };

String _convictionLabel(ConvictionLevel conviction) => switch (conviction) {
      ConvictionLevel.alta => 'alta',
      ConvictionLevel.moderada => 'moderada',
      ConvictionLevel.baja => 'baja',
    };

/// El bloque Markdown con lo que la Ficha sabe del activo.
String buildIntelligenceNoteMarkdown(DeepIntelligence intelligence) {
  final lines = <String>[];
  final name = intelligence.companyName;
  final generated =
      DateFormat('dd/MM/yyyy HH:mm').format(intelligence.generatedAt.toLocal());

  lines.add('## $kIntelligenceSnippetHeading — ${intelligence.ticker}');
  lines.add('');
  lines.add(
    // La fecha de generación va arriba y siempre: una tesis pegada hace ocho meses y una de ayer se
    // leen igual en el cuerpo de una nota, y confundirlas es el error más caro posible acá.
    '_${name == null ? "" : "$name · "}Datos de la Ficha generada el $generated._',
  );
  lines.add('');

  // --- Fundamentales ---
  lines.add('### Fundamentales');
  lines.add('');
  final fundamentals = intelligence.fundamentals;
  if (fundamentals.availability == DataAvailability.unavailable) {
    lines.add(
      '> Sin datos de fundamentales al momento de tomar esta nota'
      '${fundamentals.degradationReason == null ? "" : ": ${fundamentals.degradationReason}"}.',
    );
  } else {
    lines.add('- Salud financiera: **${_healthLabel(fundamentals.financialHealth)}**');
    if (fundamentals.period != null) {
      lines.add('- Período: ${fundamentals.period}');
    }
    for (final ratio in fundamentals.ratios.where((item) => item.isAvailable)) {
      lines.add('- ${ratio.label}: `${ratio.formatted}`');
    }
    for (final note in fundamentals.financialHealthNotes) {
      lines.add('- $note');
    }
    if (fundamentals.availability == DataAvailability.partial) {
      lines.add(
        '- _Bloque parcial: ${fundamentals.availableCount} de '
        '${fundamentals.ratios.length} ratios disponibles._',
      );
    }
  }
  lines.add('');

  // --- Síntesis de la IA ---
  lines.add('### Síntesis de reportes');
  lines.add('');
  final rag = intelligence.ragSummary;
  if (rag.availability == DataAvailability.unavailable) {
    lines.add(
      '> Sin síntesis disponible'
      '${rag.degradationReason == null ? "" : ": ${rag.degradationReason}"}.',
    );
  } else {
    if (rag.headline != null) {
      lines.add('**${rag.headline}**');
      lines.add('');
    }
    for (final point in rag.keyPoints) {
      lines.add('- $point');
    }
    if (rag.risks.isNotEmpty) {
      lines.add('');
      lines.add('**Riesgos señalados:**');
      for (final risk in rag.risks) {
        lines.add('- $risk');
      }
    }
    if (rag.sources.isNotEmpty) {
      lines.add('');
      // Las fuentes se copian porque son lo que hace verificable la síntesis dentro de la nota. Sin
      // ellas, el texto pegado queda como una afirmación sin respaldo.
      lines.add(
        '_Fuentes: ${rag.sources.map((source) => source.refId).join(", ")}._',
      );
    }
  }
  lines.add('');

  // --- Proyecciones ---
  lines.add('### Proyecciones');
  lines.add('');
  final projections = intelligence.projections;
  if (!projections.hasAny) {
    lines.add(
      '> Sin proyecciones disponibles'
      '${projections.degradationReason == null ? "" : ": ${projections.degradationReason}"}.',
    );
  } else {
    final shortTerm = projections.shortTerm;
    if (shortTerm != null) {
      lines.add(
        '**${shortTerm.horizonLabel}** — ${_trendLabel(shortTerm.trend)} '
        '(confianza ${_confidenceLabel(shortTerm.confidence)})',
      );
      lines.add('');
      lines.add(shortTerm.argument);
      lines.add('');
    }

    final mediumTerm = projections.mediumTerm;
    if (mediumTerm != null) {
      lines.add(
        '**${mediumTerm.horizonLabel}** '
        '(confianza ${_confidenceLabel(mediumTerm.confidence)})',
      );
      lines.add('');
      for (final scenario in mediumTerm.scenarios) {
        final probability = scenario.probabilityPct;
        lines.add(
          '- ${scenario.label}'
          // Sin probabilidad se omite el número en vez de poner un 0: un escenario "al 0%" se
          // leería como descartado, y lo que pasó es que no se pudo cuantificar.
          '${probability == null ? "" : " (${probability.toStringAsFixed(0)}%)"}: '
          '${scenario.narrative}',
        );
      }
      if (mediumTerm.catalysts.isNotEmpty) {
        lines.add('');
        lines.add('**Catalizadores:** ${mediumTerm.catalysts.join("; ")}');
      }
      lines.add('');
    }

    final longTerm = projections.longTerm;
    if (longTerm != null) {
      lines.add(
        '**${longTerm.horizonLabel}** '
        '(convicción ${_convictionLabel(longTerm.conviction)})',
      );
      lines.add('');
      lines.add(longTerm.thesis);
      if (longTerm.supportingFactors.isNotEmpty) {
        lines.add('');
        lines.add('**A favor:**');
        for (final factor in longTerm.supportingFactors) {
          lines.add('- $factor');
        }
      }
      if (longTerm.invalidationTriggers.isNotEmpty) {
        lines.add('');
        // Lo que invalidaría la tesis es la parte que más importa conservar en una nota: es contra
        // qué se va a chequear la posición dentro de tres meses.
        lines.add('**Qué invalidaría la tesis:**');
        for (final trigger in longTerm.invalidationTriggers) {
          lines.add('- $trigger');
        }
      }
      lines.add('');
    }
  }

  lines.add('---');
  lines.add('');
  lines.add(
    '_Bloque insertado desde la Ficha de Inteligencia. Análisis automático sobre reportes '
    'públicos: no es asesoramiento financiero._',
  );

  return lines.join('\n');
}

/// Borrador de una nota nueva con la Ficha ya pegada, lista para que el usuario escriba su propia
/// lectura arriba.
///
/// El título lleva la fecha porque estas notas se acumulan: tres "Ficha de NVDA" sin fecha son
/// indistinguibles en el explorador.
NoteDraft intelligenceNoteDraft(
  DeepIntelligence intelligence, {
  String? folderId,
}) {
  final date = DateFormat('dd/MM/yyyy').format(intelligence.generatedAt.toLocal());
  return NoteDraft.blank(
    folderId: folderId,
    ticker: intelligence.ticker,
    title: '${intelligence.ticker} — Ficha del $date',
    content: buildIntelligenceNoteMarkdown(intelligence),
  );
}

/// Agrega el bloque al final de un cuerpo que ya existe.
///
/// Se **agrega** y nunca reemplaza: el cuerpo actual puede ser la tesis que el usuario escribió a
/// mano, y sobreescribirla con datos que se pueden volver a generar sería la peor pérdida posible en
/// este módulo.
String appendIntelligenceSnippet(String existingContent, DeepIntelligence data) {
  final snippet = buildIntelligenceNoteMarkdown(data);
  final trimmed = existingContent.trimRight();
  if (trimmed.isEmpty) return snippet;
  return '$trimmed\n\n$snippet';
}
