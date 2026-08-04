import 'package:flutter/material.dart';

import '../layout/breakpoints.dart';
import '../theme/app_theme.dart';

/// Layout de dos paneles para pantallas anchas: lista a la izquierda, detalle a la derecha.
/// Abajo de `Breakpoints.masterDetail` devuelve solo el panel maestro — el detalle se navega
/// como pantalla aparte, que es la única forma legible de mostrarlo en un ancho de teléfono.
///
/// El ancho del panel maestro es fijo (no un `flex`): una lista de tickers no gana nada con
/// 800px de ancho, y dejarla crecer le robaría al detalle, que sí los necesita para el chart.
class MasterDetailLayout extends StatelessWidget {
  const MasterDetailLayout({
    super.key,
    required this.master,
    required this.detail,
    this.masterWidth = 380,
  });

  final Widget master;

  /// Se construye con `null` cuando no hay nada seleccionado, para que el panel pueda mostrar
  /// su propio placeholder en vez de quedar en blanco.
  final Widget detail;

  final double masterWidth;

  @override
  Widget build(BuildContext context) {
    if (!context.isMasterDetail) return master;

    return Row(
      children: [
        SizedBox(width: masterWidth, child: master),
        const VerticalDivider(width: 1, thickness: 1, color: AppTheme.border),
        Expanded(child: detail),
      ],
    );
  }
}

/// Placeholder del panel derecho cuando todavía no se eligió nada. Un panel vacío sin texto
/// parece un error de render; esto dice explícitamente que falta elegir.
class DetailPanelPlaceholder extends StatelessWidget {
  const DetailPanelPlaceholder({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insights_outlined, size: 44, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
