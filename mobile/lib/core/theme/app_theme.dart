import 'package:flutter/material.dart';

/// Tema único de la app — fintech dark-first (igual que la mayoría de apps de trading), con
/// colores semánticos para urgencia/escenarios reutilizados en Dashboard, Ficha y Watchlist.
class AppTheme {
  const AppTheme._();

  static const Color bullish = Color(0xFF22C55E);
  static const Color bearish = Color(0xFFEF4444);
  static const Color neutral = Color(0xFFF59E0B);

  static ThemeData get dark => ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF6366F1),
        scaffoldBackgroundColor: const Color(0xFF0B0F14),
      );
}
