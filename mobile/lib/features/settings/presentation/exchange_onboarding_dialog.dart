import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../data/exchange_type.dart';

/// Diálogo de bienvenida que pide elegir la bolsa preferida la primera vez. No es
/// descartable (`barrierDismissible: false`, sin botón de cerrar): elegir una opción es lo
/// único que lo cierra, así no queda un estado "sin preferencia" que vuelva a aparecer en
/// cada navegación.
class ExchangeOnboardingDialog extends ConsumerWidget {
  const ExchangeOnboardingDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const ExchangeOnboardingDialog(),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlertDialog(
      title: const Text('¿Qué bolsa seguís?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Elegí tu bolsa principal para enfocar el dashboard. Podés cambiarla cuando '
            'quieras desde el ícono en la barra superior.',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 16),
          for (final exchange in ExchangeType.values)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                title: Text(
                  exchange.displayName,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(exchange.description),
                onTap: () async {
                  await ref
                      .read(exchangeControllerProvider.notifier)
                      .select(exchange);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            ),
        ],
      ),
    );
  }
}
