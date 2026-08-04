import 'package:flutter/material.dart';

/// Sistema de diseño de la app — "Financial Pro": dark-first, superficies en capas, bordes
/// definidos y números monoespaciados. Un único lugar del que salen los colores, el radio y los
/// estilos de texto: si una pantalla define su propio gris o su propio radio, deja de verse
/// parte del mismo producto.
class AppTheme {
  const AppTheme._();

  // --- Paleta semántica -------------------------------------------------------------------
  // Verde esmeralda / rojo coral: la convención de las terminales financieras. Se usan SOLO
  // para dirección del movimiento (sube/baja), nunca como color decorativo — si el verde
  // apareciera en un botón cualquiera, dejaría de leerse como "ganancia".
  static const Color bullish = Color(0xFF10B981);
  static const Color bearish = Color(0xFFF87171);

  /// Ámbar para lo intermedio (urgencia media, escenario neutral, dato ausente).
  static const Color neutral = Color(0xFFF59E0B);

  /// Cian de acento: botones, selecciones activas, foco. Deliberadamente fuera del par
  /// verde/rojo para que una acción de la UI nunca se confunda con una señal de mercado.
  static const Color accent = Color(0xFF22D3EE);

  // --- Superficies ------------------------------------------------------------------------
  /// Fondo base de la ventana.
  static const Color background = Color(0xFF0B0F19);

  /// Cards, paneles y nav lateral — un escalón por encima del fondo.
  static const Color surface = Color(0xFF131C2E);

  /// Campos de entrada y celdas hundidas: un escalón por DEBAJO de `surface`, para que un input
  /// dentro de una card se lea como hueco y no como otra card apilada.
  static const Color surfaceSunken = Color(0xFF0F1725);

  /// Bordes y divisores. Borde visible en vez de sombra a propósito: en dark mode la sombra
  /// casi no se percibe, y el borde es lo que da la definición de terminal financiera.
  static const Color border = Color(0xFF1E293B);

  /// Texto secundario. Un gris con un dejo de azul (no `Colors.grey`) para que no se vea
  /// "sucio" contra los fondos azulados.
  static const Color textMuted = Color(0xFF94A3B8);

  static const double radius = 12;

  static BoxDecoration get panelDecoration => BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border),
      );

  // --- Tipografía de datos ----------------------------------------------------------------
  /// Símbolos de ticker: monoespaciada y en negrita, es el ancla visual de cada fila/tile.
  static const TextStyle tickerSymbol = TextStyle(
    fontFamily: 'AppMono',
    fontWeight: FontWeight.bold,
    letterSpacing: 0.5,
  );

  /// Precios y porcentajes. `color` se pasa desde el call site (bullish/bearish según el signo).
  static TextStyle numeric({double fontSize = 13, Color? color}) => TextStyle(
        fontFamily: 'AppMono',
        fontSize: fontSize,
        color: color,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// Chip/badge de bolsa o de urgencia, tintado con `color`.
  static BoxDecoration badgeDecoration(Color color) => BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      );

  static ThemeData get dark {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.dark,
      ).copyWith(
        surface: background,
        surfaceContainerHighest: surface,
        primary: accent,
        onPrimary: background,
        outline: border,
      ),
      scaffoldBackgroundColor: background,
      dividerColor: border,
    );

    // Sin la parte de tipografía, la default de Material3 referencia "Roboto" y el motor
    // CanvasKit (Web) intenta bajarla de fonts.gstatic.com en el primer frame si no está
    // bundleada — en una red restringida (o sin acceso a Google Fonts) el texto queda
    // invisible sin ningún error visible. "AppSans"/"AppMono" son Liberation Sans/Mono,
    // bundleadas en assets/fonts/ (ver pubspec.yaml) — nunca se piden por red.
    // `TextTheme.apply` reescribe el fontFamily de cada estilo ya generado; pasar `fontFamily`
    // al constructor de `ThemeData` no alcanza porque Material3 arma su propia `Typography`.
    final textTheme = base.textTheme.apply(fontFamily: 'AppSans').copyWith(
          // Jerarquía de encabezados un poco más apretada que la default de Material3, que está
          // pensada para contenido editorial y deja los títulos enormes en una app de datos.
          headlineMedium: base.textTheme.headlineMedium?.copyWith(
            fontFamily: 'AppSans',
            fontWeight: FontWeight.bold,
            letterSpacing: -0.5,
          ),
          titleLarge: base.textTheme.titleLarge?.copyWith(
            fontFamily: 'AppSans',
            fontWeight: FontWeight.bold,
          ),
          titleMedium: base.textTheme.titleMedium?.copyWith(
            fontFamily: 'AppSans',
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
        );

    return base.copyWith(
      textTheme: textTheme,
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'AppSans'),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
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
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: accent.withValues(alpha: 0.18),
        labelTextStyle: WidgetStatePropertyAll(
          textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: surface,
        indicatorColor: accent.withValues(alpha: 0.18),
        labelType: NavigationRailLabelType.all,
        selectedIconTheme: const IconThemeData(color: accent),
        selectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: accent,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: textMuted,
        ),
      ),
      listTileTheme: const ListTileThemeData(
        selectedColor: accent,
        selectedTileColor: Color(0xFF16233A),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceSunken,
        hintStyle: const TextStyle(color: textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius - 4),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius - 4),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius - 4),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius - 4),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: accent,
          side: const BorderSide(color: border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius - 4),
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: accent,
        foregroundColor: background,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: accent.withValues(alpha: 0.18),
          selectedForegroundColor: accent,
          side: const BorderSide(color: border),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: accent),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? accent : null,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? accent.withValues(alpha: 0.35)
              : null,
        ),
      ),
    );
  }
}
