import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Aviso de un bloque que el backend devolvió degradado.
///
/// La regla que este widget existe para hacer cumplir: **nunca esconder una sección ni dejarla en
/// blanco**. Una tarjeta ausente se lee como un bug; una tarjeta vacía se lee como "no hay nada que
/// decir sobre esto", que es una afirmación falsa. El banner dice qué falta y por qué, con el motivo
/// que manda el backend.
///
/// Ámbar y no rojo a propósito: que falte una credencial o que un proveedor no conteste no es la app
/// rota, y pintarlo de rojo haría que un entorno sin configurar pareciera roto.
///
/// Vive en `core/` porque ya lo usan tres contratos distintos con la misma forma de degradación —la
/// Ficha de Inteligencia Profunda, la Auditoría de Portafolio y el Hub Corporativo—: tener una copia
/// por feature dejaría que los avisos se vieran distinto según la pantalla.
class DegradationBanner extends StatelessWidget {
  const DegradationBanner({
    super.key,
    required this.reason,
    this.icon = Icons.info_outline,
  });

  final String? reason;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.neutral.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.neutral.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppTheme.neutral),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              reason ?? 'Este bloque no está disponible en este momento.',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
