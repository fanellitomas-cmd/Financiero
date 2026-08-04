import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../data/exchange_type.dart';

/// Selector rápido de bolsa para el AppBar. Un `PopupMenuButton` (no un `DropdownButton`):
/// dentro de un AppBar el dropdown hereda mal el estilo y no deja mostrar un check en la
/// opción activa, que es justamente lo que hace obvio cuál está elegida.
class ExchangeSelector extends ConsumerWidget {
  const ExchangeSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedExchangeProvider);

    return PopupMenuButton<ExchangeType>(
      tooltip: 'Cambiar de bolsa',
      onSelected: (exchange) =>
          ref.read(exchangeControllerProvider.notifier).select(exchange),
      itemBuilder: (context) => [
        for (final exchange in ExchangeType.values)
          PopupMenuItem<ExchangeType>(
            value: exchange,
            child: Row(
              children: [
                Icon(
                  exchange == selected ? Icons.check : null,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(exchange.displayName),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              // Mientras carga la preferencia (o si nunca se eligió) no se muestra ninguna
              // bolsa concreta — no se asume un default, porque sería mostrarle al usuario
              // una elección que nunca hizo.
              selected?.displayName ?? '—',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}
