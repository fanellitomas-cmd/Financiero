import 'package:flutter/material.dart';

/// Tema único de la app — fintech dark-first (igual que la mayoría de apps de trading), con
/// colores semánticos para urgencia/escenarios reutilizados en Dashboard, Ficha y Watchlist.
class AppTheme {
  const AppTheme._();

  // --- colores semánticos (dirección del movimiento) ---
  static const Color bullish = Color(0xFF22C55E);
  static const Color bearish = Color(0xFFEF4444);
  static const Color neutral = Color(0xFFF59E0B);

  // --- superficies ---
  /// Fondo base de la app.
  static const Color background = Color(0xFF0B0F19);

  /// Superficie elevada: cards, panel de detalle, nav lateral. Un escalón por encima del fondo
  /// para que las tarjetas se lean como capas y no como parches de color.
  static const Color surface = Color(0xFF1E293B);

  /// Bordes y divisores. Deliberadamente un borde visible en vez de sombras: en dark mode las
  /// sombras casi no se perciben, y el borde es lo que le da la definición "de terminal
  /// financiera" a las cards y a los paneles.
  static const Color border = Color(0xFF2B3A52);

  /// Radio de esquina único para cards, badges y paneles.
  static const double radius = 12;

  static BoxDecoration get panelDecoration => BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border),
      );

  static ThemeData get dark {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6366F1),
        brightness: Brightness.dark,
      ).copyWith(surface: background, surfaceContainerHighest: surface),
      scaffoldBackgroundColor: background,
      dividerColor: border,
    );

    // Sin la parte de tipografía, la default de Material3 referencia "Roboto" y el motor
    // CanvasKit (Web) intenta bajarla de fonts.gstatic.com en el primer frame si no está
    // bundleada — en una red restringida (o sin acceso a Google Fonts) el texto queda
    // invisible sin ningún error visible. "AppSans" es Liberation Sans, bundleada en
    // assets/fonts/ (ver pubspec.yaml) — nunca se pide por red. `TextTheme.apply` reescribe
    // el fontFamily de cada estilo ya generado; pasar `fontFamily` al constructor de
    // `ThemeData` no alcanza acá porque Material3 arma su propia `Typography` internamente.
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'AppSans'),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'AppSans'),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: border),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius + 4),
          side: const BorderSide(color: border),
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: Color(0xFF334155),
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: surface,
        indicatorColor: Color(0xFF334155),
        labelType: NavigationRailLabelType.all,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFF16202F),
        border: OutlineInputBorder(
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: border),
        ),
      ),
    );
  }
}
