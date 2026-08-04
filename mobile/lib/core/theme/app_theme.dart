import 'package:flutter/material.dart';

/// Tema único de la app — fintech dark-first (igual que la mayoría de apps de trading), con
/// colores semánticos para urgencia/escenarios reutilizados en Dashboard, Ficha y Watchlist.
class AppTheme {
  const AppTheme._();

  static const Color bullish = Color(0xFF22C55E);
  static const Color bearish = Color(0xFFEF4444);
  static const Color neutral = Color(0xFFF59E0B);

  static ThemeData get dark {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorSchemeSeed: const Color(0xFF6366F1),
      scaffoldBackgroundColor: const Color(0xFF0B0F14),
    );

    // Sin esto, la tipografía default de Material3 referencia "Roboto" y el motor
    // CanvasKit (Web) intenta bajarla de fonts.gstatic.com en el primer frame si no está
    // bundleada — en una red restringida (o sin acceso a Google Fonts) el texto queda
    // invisible sin ningún error visible. "AppSans" es Liberation Sans, bundleada en
    // assets/fonts/ (ver pubspec.yaml) — nunca se pide por red. `TextTheme.apply` reescribe
    // el fontFamily de cada estilo ya generado; pasar `fontFamily` al constructor de
    // `ThemeData` no alcanza acá porque Material3 arma su propia `Typography` internamente.
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'AppSans'),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'AppSans'),
    );
  }
}
