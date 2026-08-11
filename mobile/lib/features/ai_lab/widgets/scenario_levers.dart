import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Una palanca del simulador: un slider que puede estar **sin fijar**.
///
/// El estado "sin fijar" es el corazón de este control y no un detalle de UI. En dos de las cuatro
/// palancas, `null` y `0` son escenarios distintos:
///
///   - Un **margen EBITDA** sin fijar deja que la inflación lo mueva según el traspaso a precios que
///     el backend declara. Un margen fijado en un valor lo congela ahí y anula ese efecto.
///   - Una **tasa de interés** sin fijar mantiene el gasto de intereses del último balance. Una tasa
///     fijada lo recalcula sobre la deuda.
///
/// Un slider que arranca en un número ya sería un supuesto del usuario que él no eligió. Por eso la
/// palanca arranca apagada, y encenderla es un gesto explícito con un valor visible desde el primer
/// momento.
class ScenarioLever extends StatelessWidget {
  const ScenarioLever({
    super.key,
    required this.label,
    required this.helper,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.onActivate,
    this.divisions,
    this.baselineLabel,
    this.signed = true,
    this.enabled = true,
  });

  final String label;

  /// Qué hace la palanca cuando está sin fijar. Es la explicación que evita el error de creer que una
  /// palanca apagada equivale a ponerla en cero.
  final String helper;

  /// `null` = sin fijar.
  final double? value;

  final double min;
  final double max;
  final int? divisions;

  /// Se llama con el valor nuevo, o con `null` para volver a "sin fijar".
  final ValueChanged<double?> onChanged;

  /// Encender la palanca. Es un callback aparte de `onChanged` porque el valor inicial no lo decide
  /// este widget: para el margen y la tasa se parte del dato REAL de la empresa cuando se lo conoce.
  final VoidCallback onActivate;

  /// El valor del período base, para poder mostrar de dónde parte.
  final String? baselineLabel;

  /// `true` cuando el número es una VARIACIÓN (un crecimiento de ingresos, una inflación) y por lo
  /// tanto el signo forma parte del dato; `false` cuando es un NIVEL (el margen EBITDA al que se
  /// congela la proyección, la tasa a la que se recalculan los intereses).
  ///
  /// La distinción no es cosmética: un margen de 63,9% mostrado como "+63,9%" se lee como "63,9
  /// puntos MÁS de margen", que es un escenario completamente distinto del que la palanca aplica.
  final bool signed;

  final bool enabled;

  bool get isSet => value != null;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      decoration: BoxDecoration(
        color: isSet ? AppTheme.surface : AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(
          color: isSet ? AppTheme.accent.withValues(alpha: 0.35) : AppTheme.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: isSet ? AppTheme.accent : null,
                      ),
                    ),
                    if (baselineLabel != null)
                      Text(
                        baselineLabel!,
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppTheme.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
              if (isSet)
                Text(
                  _formatValue(value!),
                  style: AppTheme.numeric(fontSize: 14, color: AppTheme.accent)
                      .copyWith(fontWeight: FontWeight.bold),
                )
              else
                const Text(
                  'sin fijar',
                  style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                ),
              // El switch es lo que hace visible que "apagada" es un estado distinto de "en cero".
              Switch(
                value: isSet,
                onChanged: enabled
                    ? (turnedOn) {
                        if (turnedOn) {
                          onActivate();
                        } else {
                          onChanged(null);
                        }
                      }
                    : null,
              ),
            ],
          ),
          if (isSet)
            Slider(
              value: value!.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              label: _formatValue(value!),
              onChanged: enabled ? (next) => onChanged(next) : null,
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 8, top: 2),
              child: Text(
                helper,
                style: const TextStyle(
                  fontSize: 10.5,
                  color: AppTheme.textMuted,
                  height: 1.35,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _formatValue(double raw) {
    final rounded = raw.toStringAsFixed(1).replaceAll('.', ',');
    if (raw < 0) return '$rounded%'.replaceAll('-', '−');
    return signed && raw > 0 ? '+$rounded%' : '$rounded%';
  }
}
