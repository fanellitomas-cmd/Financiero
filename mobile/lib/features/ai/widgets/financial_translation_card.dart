import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/theme/app_theme.dart';
import '../data/financial_translation.dart';
import '../presentation/financial_translator_controller.dart';

/// Traducción de un texto técnico a lenguaje simple, lista para intercalar debajo de cualquier
/// bloque de la app.
///
/// Es el widget que materializa el modo "Explicar para Principiantes": se le pasa el texto técnico
/// que ya está en pantalla y el contexto de dónde salió, y él se encarga del pedido, de los estados
/// y de la degradación.
///
/// Tres decisiones de diseño:
///
///  1. **La analogía va en su propia tarjeta**, visualmente separada de la explicación. Una
///     analogía es una ayuda para entender, no una afirmación sobre la empresa: mezclarlas dejaría
///     al lector sin saber cuál de las dos frases es el dato.
///  2. **No reemplaza al original.** Se suma abajo, con el bloque técnico intacto arriba. Sustituir
///     el texto le sacaría al usuario la posibilidad de aprender a leerlo, que es el punto de tener
///     un traductor y no dos versiones de la app.
///  3. **Cuando no está disponible se dice, en tono de aviso.** Que falte una credencial no es la
///     app rota, y el toggle es una ayuda opcional.
class FinancialTranslationCard extends ConsumerWidget {
  const FinancialTranslationCard({
    super.key,
    required this.text,
    this.context,
    this.label,
  });

  /// El texto técnico a traducir. Se le pasa ya compuesto por el llamador: cada sección sabe cuál
  /// de sus partes vale la pena explicar, y mandar la sección entera diluiría la explicación.
  final String text;

  /// De dónde salió (ticker, nombre de la sección). Mejora la traducción y entra en la clave de
  /// caché del backend.
  final String? context;

  /// Título de la tarjeta. Por defecto nombra la función, no el contenido.
  final String? label;

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final request = TranslationRequest(text: text, context: context);
    final async = ref.watch(financialTranslationProvider(request));

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        // Fondo tintado en cian (el acento) y borde marcado: el bloque tiene que leerse como una
        // capa de ayuda agregada, no como más contenido de la sección que lo contiene.
        color: AppTheme.accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardHeader(label: label ?? 'En palabras simples'),
          const SizedBox(height: 10),
          switch (async) {
            AsyncValue(:final error?) => _Message(
                text: describeApiError(error),
                icon: Icons.cloud_off_outlined,
              ),
            AsyncValue(valueOrNull: final translation?) =>
              _TranslationBody(translation: translation),
            _ => const _Loading(),
          },
        ],
      ),
    );
  }
}

class _CardHeader extends StatelessWidget {
  const _CardHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.volunteer_activism_outlined,
            size: 15, color: AppTheme.accent),
        const SizedBox(width: 7),
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.accent,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        SizedBox(width: 10),
        Text(
          'Traduciendo…',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.icon});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: AppTheme.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: AppTheme.textMuted,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

class _TranslationBody extends StatelessWidget {
  const _TranslationBody({required this.translation});

  final FinancialTranslation translation;

  @override
  Widget build(BuildContext context) {
    if (!translation.available) {
      return _Message(
        text: translation.degradationReason ??
            'La explicación simple no está disponible en este momento.',
        icon: Icons.info_outline,
      );
    }

    final analogy = translation.analogy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          translation.simpleExplanation ?? '',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        // La analogía puede faltar y eso es un resultado válido: para un término sin equivalente
        // cotidiano, forzar una analogía produce una peor que ninguna.
        if (analogy != null) ...[
          const SizedBox(height: 12),
          _AnalogyCard(analogy: analogy),
        ],
        if (translation.keyTerms.isNotEmpty) ...[
          const SizedBox(height: 12),
          _Glossary(entries: translation.keyTerms),
        ],
      ],
    );
  }
}

/// Tarjeta destacada de la analogía cotidiana.
///
/// Separada visualmente y con su propio ícono porque es lo único del bloque que **no** es una
/// afirmación sobre el activo: es una comparación para entender. Un lector apurado tiene que poder
/// distinguirla del dato sin leer las dos.
class _AnalogyCard extends StatelessWidget {
  const _AnalogyCard({required this.analogy});

  final String analogy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border:
            const Border(left: BorderSide(color: AppTheme.neutral, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lightbulb_outline,
                  size: 13, color: AppTheme.neutral),
              const SizedBox(width: 6),
              Text(
                'PARA QUE TE DÉS UNA IDEA',
                style: AppTheme.numeric(
                  fontSize: 9,
                  color: AppTheme.neutral,
                ).copyWith(fontWeight: FontWeight.bold, letterSpacing: 0.5),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            analogy,
            style: const TextStyle(
              fontSize: 12,
              height: 1.5,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

/// Glosario de los tecnicismos que aparecían en el texto original.
///
/// Solo los que estaban: el backend no agrega términos "relacionados" que el lector no vio, así que
/// esta lista es exactamente el vocabulario que le hizo falta para leer ESE bloque.
class _Glossary extends StatelessWidget {
  const _Glossary({required this.entries});

  final List<GlossaryEntry> entries;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1, color: AppTheme.border),
        const SizedBox(height: 10),
        Text(
          'Qué significa cada término',
          style: AppTheme.numeric(fontSize: 10, color: AppTheme.textMuted)
              .copyWith(fontWeight: FontWeight.bold, letterSpacing: 0.4),
        ),
        const SizedBox(height: 8),
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 1),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: AppTheme.accent.withValues(alpha: 0.30),
                    ),
                  ),
                  child: Text(
                    entry.term,
                    style: AppTheme.numeric(
                      fontSize: 10,
                      color: AppTheme.accent,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.plainMeaning,
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// El switch "Explicar para Principiantes".
///
/// Vive acá y no dentro de la Ficha para que cualquier pantalla con análisis técnico pueda ofrecerlo
/// con el mismo aspecto y el mismo estado global — alguien que necesita las explicaciones simples
/// las necesita en toda la app, no solo en la pantalla donde encontró el switch.
class BeginnerModeToggle extends ConsumerWidget {
  const BeginnerModeToggle({super.key, this.compact = false});

  /// En `compact` va sin la etiqueta larga: es para cabeceras angostas donde el texto completo no
  /// entra sin desplazar el título.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOn = ref.watch(beginnerModeProvider);

    return Tooltip(
      message: isOn
          ? 'Explicaciones simples activadas'
          : 'Explicar los términos técnicos en palabras simples',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.volunteer_activism_outlined,
            size: 15,
            color: isOn ? AppTheme.accent : AppTheme.textMuted,
          ),
          const SizedBox(width: 6),
          if (!compact)
            Text(
              'Explicar simple',
              style: TextStyle(
                fontSize: 12,
                color: isOn ? AppTheme.accent : AppTheme.textMuted,
                fontWeight: isOn ? FontWeight.bold : null,
              ),
            ),
          Switch(
            value: isOn,
            // `visualDensity` compacto: el switch va en la cabecera de una card, y el tamaño por
            // defecto de Material la haría crecer casi el doble.
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (value) =>
                ref.read(beginnerModeProvider.notifier).state = value,
          ),
        ],
      ),
    );
  }
}
