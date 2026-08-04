import 'package:financiero_app/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Los tokens del sistema de diseño se testean por valor exacto a propósito: son un contrato
/// acordado con diseño, y un cambio accidental (un color pisado, un radio distinto) es
/// exactamente la clase de regresión que no se nota mirando una pantalla suelta.
void main() {
  group('tokens de color', () {
    test('las superficies son las de la especificación', () {
      expect(AppTheme.background, const Color(0xFF0B0F19));
      expect(AppTheme.surface, const Color(0xFF131C2E));
      expect(AppTheme.border, const Color(0xFF1E293B));
    });

    test('las superficies forman capas de oscuro a claro', () {
      // El orden importa: si `surfaceSunken` quedara más claro que `surface`, un input dentro
      // de una card se vería flotando en vez de hundido.
      double luminance(Color c) => c.computeLuminance();
      expect(
        luminance(AppTheme.surfaceSunken),
        lessThan(luminance(AppTheme.surface)),
      );
      expect(
        luminance(AppTheme.background),
        lessThan(luminance(AppTheme.surface)),
      );
    });

    test('el acento no está en la familia verde/rojo de las señales de mercado',
        () {
      // Un botón nunca debe leerse como "ganancia" ni como "pérdida".
      expect(AppTheme.accent, isNot(AppTheme.bullish));
      expect(AppTheme.accent, isNot(AppTheme.bearish));
      // Cian: el canal azul domina sobre el rojo.
      expect(AppTheme.accent.b, greaterThan(AppTheme.accent.r));
    });

    test('bullish y bearish son distinguibles entre sí', () {
      expect(AppTheme.bullish, isNot(AppTheme.bearish));
      expect(AppTheme.bullish.g, greaterThan(AppTheme.bullish.r));
      expect(AppTheme.bearish.r, greaterThan(AppTheme.bearish.g));
    });
  });

  group('tipografía', () {
    test('los estilos de datos usan la monoespaciada bundleada', () {
      expect(AppTheme.tickerSymbol.fontFamily, 'AppMono');
      expect(AppTheme.numeric().fontFamily, 'AppMono');
    });

    test('numeric usa cifras tabulares para que los dígitos alineen', () {
      expect(
        AppTheme.numeric().fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    });

    test('el tema usa la sans bundleada, nunca Roboto (que se baja por red)',
        () {
      // Esta es la regresión que dejó la app con texto invisible una vez: si el fontFamily
      // vuelve a ser null/Roboto, CanvasKit intenta bajarla de fonts.gstatic.com.
      final theme = AppTheme.dark;
      expect(theme.textTheme.bodyMedium?.fontFamily, 'AppSans');
      expect(theme.textTheme.titleLarge?.fontFamily, 'AppSans');
      expect(theme.textTheme.headlineMedium?.fontFamily, 'AppSans');
    });
  });

  group('ThemeData', () {
    test('el fondo del scaffold y el colorScheme salen de los tokens', () {
      final theme = AppTheme.dark;
      expect(theme.scaffoldBackgroundColor, AppTheme.background);
      expect(theme.colorScheme.primary, AppTheme.accent);
      expect(theme.dividerColor, AppTheme.border);
      expect(theme.brightness, Brightness.dark);
    });

    test('cards y diálogos llevan borde visible en vez de sombra', () {
      // En dark mode la sombra no se percibe; el borde es lo que define la superficie.
      final theme = AppTheme.dark;
      expect(theme.cardTheme.elevation, 0);
      expect(theme.cardTheme.color, AppTheme.surface);

      final cardShape = theme.cardTheme.shape as RoundedRectangleBorder;
      expect(cardShape.side.color, AppTheme.border);
      expect(cardShape.borderRadius, BorderRadius.circular(AppTheme.radius));
    });

    test('los inputs se pintan sobre la superficie hundida', () {
      final theme = AppTheme.dark;
      expect(theme.inputDecorationTheme.filled, isTrue);
      expect(theme.inputDecorationTheme.fillColor, AppTheme.surfaceSunken);
    });
  });
}
