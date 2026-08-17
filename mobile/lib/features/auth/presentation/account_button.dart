import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/theme/app_theme.dart';

/// Menú de cuenta con el cierre de sesión.
///
/// Un menú y no un `IconButton` directo: cerrar sesión con un solo toque sobre un ícono en la barra
/// es demasiado fácil de hacer sin querer, y la confirmación de abajo es lo que evita perder la
/// sesión por un dedo mal puesto.
///
/// Se muestra en el AppBar del Dashboard (que es el que ven todos al entrar) y al pie del rail de
/// navegación en escritorio. No hay una barra global donde ponerlo una sola vez: cada pantalla del
/// shell trae su propio AppBar.
class AccountButton extends ConsumerWidget {
  const AccountButton({super.key, this.compact = false});

  /// `true` en el rail de escritorio, donde el botón va suelto al pie y sin AppBar alrededor.
  final bool compact;

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('¿Cerrar sesión?'),
        content: const Text(
          'Tus notas, watchlist y carteras quedan guardadas en tu cuenta: las vas a ver igual '
          'cuando vuelvas a entrar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Cerrar sesión'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    // No se navega a mano: al quedar sin sesión, el `redirect` del router manda a `/auth` solo. Un
    // `context.go` acá competiría con esa redirección.
    await ref.read(authControllerProvider.notifier).logout();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final icon = Icon(
      Icons.account_circle_outlined,
      size: compact ? 22 : 24,
      color: compact ? AppTheme.textMuted : null,
    );

    return PopupMenuButton<String>(
      tooltip: 'Cuenta',
      icon: icon,
      position: PopupMenuPosition.under,
      itemBuilder: (menuContext) => [
        const PopupMenuItem(
          value: 'logout',
          child: Row(
            children: [
              Icon(Icons.logout, size: 17),
              SizedBox(width: 10),
              Text('Cerrar sesión'),
            ],
          ),
        ),
      ],
      onSelected: (value) {
        if (value == 'logout') _confirmLogout(context, ref);
      },
    );
  }
}
