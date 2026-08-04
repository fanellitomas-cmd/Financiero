import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../settings/data/exchange_type.dart';
import '../data/ticker.dart';
import 'ticker_search_controller.dart';

/// Buscador incremental de acciones sobre el catálogo del backend. Reemplaza la entrada manual
/// del símbolo: el usuario escribe "nvidia" o "nvda" y elige de una lista real, así no puede
/// tipear un símbolo que no existe.
class TickerSearchField extends ConsumerStatefulWidget {
  const TickerSearchField({
    super.key,
    required this.onSelected,
    this.filterExchange,
  });

  final ValueChanged<Ticker> onSelected;

  /// Cuando viene una bolsa, la búsqueda se restringe a ella (la que el usuario eligió en el
  /// AppBar). `null` busca en todas.
  final ExchangeType? filterExchange;

  @override
  ConsumerState<TickerSearchField> createState() => _TickerSearchFieldState();
}

class _TickerSearchFieldState extends ConsumerState<TickerSearchField> {
  final _inputController = TextEditingController();

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(tickerSearchControllerProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _inputController,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            labelText: 'Buscar acción',
            hintText: 'ej: NVDA, apple, coca',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: state.isLoading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
          onChanged: (value) => ref
              .read(tickerSearchControllerProvider.notifier)
              .onQueryChanged(value, exchange: widget.filterExchange),
        ),
        const SizedBox(height: 8),
        _Results(
          state: state,
          query: _inputController.text.trim(),
          filterExchange: widget.filterExchange,
          onSelected: widget.onSelected,
        ),
      ],
    );
  }
}

class _Results extends StatelessWidget {
  const _Results({
    required this.state,
    required this.query,
    required this.filterExchange,
    required this.onSelected,
  });

  final TickerSearchState state;
  final String query;
  final ExchangeType? filterExchange;
  final ValueChanged<Ticker> onSelected;

  @override
  Widget build(BuildContext context) {
    if (state.errorMessage != null) {
      return _Hint(text: state.errorMessage!, isError: true);
    }
    if (query.isEmpty) {
      return const _Hint(text: 'Escribí un símbolo o el nombre de la empresa.');
    }
    if (state.results.isEmpty) {
      if (state.isLoading) return const SizedBox(height: 64);
      // Distinguir "no hay resultados" de "el catálogo está vacío" es clave: sin el sync
      // corrido (`scripts/sync_tickers.py`) TODA búsqueda vuelve vacía, y sin este texto
      // parecería que el buscador está roto.
      final scope =
          filterExchange != null ? ' en ${filterExchange!.displayName}' : '';
      return _Hint(
        text: 'Sin resultados para "$query"$scope.\n'
            'Si el catálogo nunca se sincronizó en el backend, todas las búsquedas '
            'van a volver vacías.',
      );
    }

    return ConstrainedBox(
      // Altura acotada: la lista vive dentro de un AlertDialog, que no le da límite propio y
      // dejaría el ListView sin altura definida (error de layout).
      constraints: const BoxConstraints(maxHeight: 260),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: state.results.length,
        itemBuilder: (context, index) {
          final ticker = state.results[index];
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              ticker.symbol,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              ticker.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: _ExchangeBadge(ticker: ticker),
            onTap: () => onSelected(ticker),
          );
        },
      ),
    );
  }
}

class _ExchangeBadge extends StatelessWidget {
  const _ExchangeBadge({required this.ticker});

  final Ticker ticker;

  @override
  Widget build(BuildContext context) {
    // Color por bolsa para que se distingan de un vistazo en la lista; las que no son
    // NASDAQ/NYSE van en gris, sin inventarles identidad visual.
    final color = switch (ticker.exchange) {
      ExchangeType.nasdaq => AppTheme.bullish,
      ExchangeType.nyse => Theme.of(context).colorScheme.primary,
      null => Colors.grey,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        ticker.exchangeLabel,
        style:
            TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        text,
        style: TextStyle(
          color: isError ? Theme.of(context).colorScheme.error : Colors.grey,
          fontSize: 12,
        ),
      ),
    );
  }
}
