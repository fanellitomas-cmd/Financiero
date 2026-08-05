import 'dart:async';

import 'package:financiero_app/core/theme/app_theme.dart';
import 'package:financiero_app/features/ai/data/financial_translation.dart';
import 'package:financiero_app/features/ai/presentation/financial_translator_controller.dart';
import 'package:financiero_app/features/ai/widgets/financial_translation_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests del Traductor Financiero en el cliente (el toggle "Explicar para Principiantes").
///
/// Los contratos que esta pieza promete y que son fáciles de romper sin darse cuenta:
///
///   1. **La analogía va en su propia tarjeta**, separada de la explicación: es una ayuda para
///      entender, no una afirmación sobre la empresa.
///   2. **La analogía puede faltar y eso es válido.** Forzar una peor que ninguna sería enseñar algo
///      falso, así que la UI no deja un hueco ni un placeholder.
///   3. **`available == false` se muestra como aviso, no como error**: el toggle es una ayuda
///      opcional y que falte una credencial no es la app rota.
///   4. **El pedido tiene identidad estructural.** Sin `==` en la clave del `family`, cada apertura
///      de la Ficha crearía un provider nuevo y volvería a pedir la misma explicación.

FinancialTranslation _translation({
  String? explanation = 'La empresa gana menos por cada peso que vende.',
  String? analogy =
      'Es como un kiosco que vende lo mismo pero le queda menos al final del día.',
  List<GlossaryEntry> keyTerms = const [],
  bool available = true,
  String? degradationReason,
}) =>
    FinancialTranslation(
      originalText:
          'El múltiplo se comprimió por deterioro del margen operativo.',
      simpleExplanation: explanation,
      analogy: analogy,
      keyTerms: keyTerms,
      available: available,
      servedFromCache: false,
      degradationReason: degradationReason,
    );

/// Se sobreescribe el provider de traducción directo: lo que se prueba es cómo la tarjeta reacciona
/// a cada estado del backend, sin transporte en el medio.
Future<void> _pumpCard(
  WidgetTester tester,
  FutureOr<FinancialTranslation> Function() result, {
  Key? scopeKey,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      key: scopeKey,
      overrides: [
        financialTranslationProvider.overrideWith((ref, request) => result()),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FinancialTranslationCard(
              text:
                  'El múltiplo se comprimió por deterioro del margen operativo.',
              context: 'NVDA · fundamentales',
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // --- Parseo del contrato -----------------------------------------------------------------

  group('FinancialTranslation.fromJson', () {
    test('lee explicación, analogía y glosario', () {
      final translation = FinancialTranslation.fromJson(const {
        'original_text': 'EBITDA ajustado',
        'simple_explanation': 'Es la ganancia antes de descontar varias cosas.',
        'analogy': 'Es como mirar tu sueldo bruto en vez del que te queda.',
        'key_terms': [
          {
            'term': 'EBITDA',
            'plain_meaning': 'ganancia antes de intereses e impuestos.'
          },
        ],
        'available': true,
        'served_from_cache': true,
        'degradation_reason': null,
      });

      expect(translation.available, isTrue);
      expect(translation.servedFromCache, isTrue);
      expect(translation.analogy, contains('sueldo bruto'));
      expect(translation.keyTerms.single.term, 'EBITDA');
    });

    test('una respuesta no disponible no trae explicación', () {
      final translation = FinancialTranslation.fromJson(const {
        'original_text': 'EBITDA',
        'available': false,
        'degradation_reason': 'Falta GEMINI_API_KEY en .env.',
      });

      expect(translation.available, isFalse);
      expect(translation.simpleExplanation, isNull);
      expect(translation.analogy, isNull);
      expect(translation.keyTerms, isEmpty);
      expect(translation.degradationReason, 'Falta GEMINI_API_KEY en .env.');
    });
  });

  group('TranslationRequest', () {
    test('dos pedidos iguales son la misma clave de provider', () {
      // Sin igualdad estructural, cada apertura de la Ficha crearía un provider nuevo y volvería a
      // pedirle al backend la misma explicación.
      const first = TranslationRequest(text: 'P/E', context: 'NVDA');
      const second = TranslationRequest(text: 'P/E', context: 'NVDA');

      expect(first, second);
      expect(first.hashCode, second.hashCode);
    });

    test('el contexto es parte de la identidad del pedido', () {
      // El mismo término explicado sobre una tecnológica y sobre un banco no da lo mismo.
      const tech = TranslationRequest(text: 'múltiplo alto', context: 'NVDA');
      const bank = TranslationRequest(text: 'múltiplo alto', context: 'JPM');

      expect(tech, isNot(bank));
    });
  });

  // --- La tarjeta ---------------------------------------------------------------------------

  testWidgets('muestra explicación, analogía y glosario separados', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      () => _translation(
        keyTerms: const [
          GlossaryEntry(
            term: 'múltiplo',
            plainMeaning: 'cuánto paga el mercado por cada peso de ganancia.',
          ),
          GlossaryEntry(
            term: 'margen operativo',
            plainMeaning: 'qué parte de lo que vende le queda.',
          ),
        ],
      ),
    );

    expect(find.text('En palabras simples'), findsOneWidget);
    expect(
      find.text('La empresa gana menos por cada peso que vende.'),
      findsOneWidget,
    );
    // La analogía tiene su propio encabezado: un lector apurado tiene que poder distinguirla del
    // dato sin leer las dos.
    expect(find.text('PARA QUE TE DÉS UNA IDEA'), findsOneWidget);
    expect(find.textContaining('kiosco'), findsOneWidget);
    expect(find.text('Qué significa cada término'), findsOneWidget);
    expect(find.text('múltiplo'), findsOneWidget);
    expect(find.text('margen operativo'), findsOneWidget);
  });

  testWidgets('sin analogía no deja hueco ni placeholder', (tester) async {
    await _pumpCard(tester, () => _translation(analogy: null));

    expect(find.text('PARA QUE TE DÉS UNA IDEA'), findsNothing);
    expect(
      find.text('La empresa gana menos por cada peso que vende.'),
      findsOneWidget,
    );
  });

  testWidgets('sin glosario no muestra el encabezado vacío', (tester) async {
    await _pumpCard(tester, () => _translation());

    expect(find.text('Qué significa cada término'), findsNothing);
  });

  testWidgets('no disponible muestra el motivo, no un error', (tester) async {
    await _pumpCard(
      tester,
      () => _translation(
        explanation: null,
        analogy: null,
        available: false,
        degradationReason:
            'El Traductor Financiero no está configurado en este entorno.',
      ),
    );

    expect(
      find.text('El Traductor Financiero no está configurado en este entorno.'),
      findsOneWidget,
    );
    // El encabezado sigue: la tarjeta explica por qué está vacía en vez de desaparecer, que se
    // leería como que el toggle no hizo nada.
    expect(find.text('En palabras simples'), findsOneWidget);
  });

  testWidgets('mientras traduce lo dice', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          financialTranslationProvider.overrideWith(
            (ref, request) => Completer<FinancialTranslation>().future,
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: FinancialTranslationCard(text: 'EBITDA ajustado'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Traduciendo…'), findsOneWidget);
  });

  testWidgets('un fallo de red se muestra en la tarjeta', (tester) async {
    await _pumpCard(tester, () => throw Exception('sin red'));

    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
  });

  // --- El toggle ----------------------------------------------------------------------------

  testWidgets('el toggle enciende y apaga el modo principiante',
      (tester) async {
    late WidgetRef capturedRef;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, child) {
                capturedRef = ref;
                return const BeginnerModeToggle();
              },
            ),
          ),
        ),
      ),
    );

    expect(capturedRef.read(beginnerModeProvider), isFalse);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(capturedRef.read(beginnerModeProvider), isTrue);
    expect(find.text('Explicar simple'), findsOneWidget);
  });

  testWidgets('en modo compacto el toggle no muestra la etiqueta', (
    tester,
  ) async {
    // Es para cabeceras angostas: la etiqueta completa desplazaría el título de la Ficha.
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: BeginnerModeToggle(compact: true)),
        ),
      ),
    );

    expect(find.text('Explicar simple'), findsNothing);
    expect(find.byType(Switch), findsOneWidget);
  });
}
