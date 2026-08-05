/// Modelos de `POST /api/v1/ai/translate-financial` — el Traductor Financiero.
///
/// Espejan `app/schemas/translation.py`. La respuesta separa tres cosas que suelen venir mezcladas
/// en una explicación, y la UI las muestra separadas por el mismo motivo:
///
///   - `simpleExplanation`: qué dice el texto original, sin jerga.
///   - `analogy`: a qué se parece en la vida cotidiana. Va en su propia tarjeta porque es una ayuda
///     para entender, NO una afirmación sobre la empresa — mezclarla con la explicación dejaría al
///     lector sin saber cuál de las dos frases es el dato.
///   - `keyTerms`: el glosario de los tecnicismos que aparecían, para que la próxima vez que los vea
///     no necesite volver a traducir.
library;

import 'package:flutter/foundation.dart';

@immutable
class GlossaryEntry {
  const GlossaryEntry({required this.term, required this.plainMeaning});

  factory GlossaryEntry.fromJson(Map<String, dynamic> json) => GlossaryEntry(
        term: json['term'] as String,
        plainMeaning: json['plain_meaning'] as String,
      );

  final String term;
  final String plainMeaning;
}

@immutable
class FinancialTranslation {
  const FinancialTranslation({
    required this.originalText,
    required this.simpleExplanation,
    required this.analogy,
    required this.keyTerms,
    required this.available,
    required this.servedFromCache,
    required this.degradationReason,
  });

  factory FinancialTranslation.fromJson(Map<String, dynamic> json) =>
      FinancialTranslation(
        originalText: json['original_text'] as String? ?? '',
        simpleExplanation: json['simple_explanation'] as String?,
        analogy: json['analogy'] as String?,
        keyTerms: [
          for (final entry in json['key_terms'] as List? ?? [])
            GlossaryEntry.fromJson(entry as Map<String, dynamic>),
        ],
        available: json['available'] as bool? ?? false,
        servedFromCache: json['served_from_cache'] as bool? ?? false,
        degradationReason: json['degradation_reason'] as String?,
      );

  final String originalText;

  /// `null` cuando `available == false`. El backend nunca devuelve una explicación vacía con
  /// `available=True`: una respuesta en blanco se trata como no disponible del lado del servidor.
  final String? simpleExplanation;

  /// `null` es un resultado válido y esperado: para un término sin equivalente cotidiano, forzar
  /// una analogía produce una peor que ninguna.
  final String? analogy;
  final List<GlossaryEntry> keyTerms;

  final bool available;
  final bool servedFromCache;
  final String? degradationReason;
}
