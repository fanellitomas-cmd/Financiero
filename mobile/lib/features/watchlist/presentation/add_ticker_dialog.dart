import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../settings/data/exchange_type.dart';
import '../../tickers/presentation/ticker_search_field.dart';
import '../data/watchlist_models.dart';

/// Diálogo de alta de un activo. Para acciones usa el buscador sobre el catálogo del backend
/// (`GET /api/v1/tickers`) en vez de texto libre, así el usuario no puede tipear un símbolo que
/// no existe y la bolsa se resuelve sola del lado del servidor.
///
/// Mantiene el modo manual para CRIPTO a propósito: el catálogo que sincroniza el backend es de
/// acciones (`market=stocks`), así que no hay nada que buscar para una cripto — sacar la entrada
/// manual habría eliminado la posibilidad de seguir BTC.
class AddTickerDialog extends ConsumerStatefulWidget {
  const AddTickerDialog({super.key});

  /// Devuelve `true` si se agregó algo, para que quien llama invalide la lista.
  static Future<bool> show(BuildContext context) async {
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => const AddTickerDialog(),
    );
    return added ?? false;
  }

  @override
  ConsumerState<AddTickerDialog> createState() => _AddTickerDialogState();
}

class _AddTickerDialogState extends ConsumerState<AddTickerDialog> {
  final _cryptoController = TextEditingController();
  AssetType _assetType = AssetType.stock;
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _cryptoController.dispose();
    super.dispose();
  }

  Future<void> _submit(
      {required String ticker, required AssetType assetType}) async {
    if (_isSubmitting) return;
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      await ref
          .read(watchlistRepositoryProvider)
          .add(ticker: ticker, assetType: assetType);
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _errorMessage = describeApiError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedExchange = ref.watch(selectedExchangeProvider);

    return AlertDialog(
      title: const Text('Agregar a la watchlist'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<AssetType>(
              segments: const [
                ButtonSegment(value: AssetType.stock, label: Text('Acción')),
                ButtonSegment(value: AssetType.crypto, label: Text('Cripto')),
              ],
              selected: {_assetType},
              onSelectionChanged: _isSubmitting
                  ? null
                  : (selection) => setState(() {
                        _assetType = selection.first;
                        _errorMessage = null;
                      }),
            ),
            const SizedBox(height: 16),
            if (_assetType == AssetType.stock)
              _StockSearch(
                filterExchange: selectedExchange,
                isSubmitting: _isSubmitting,
                onPicked: (symbol) =>
                    _submit(ticker: symbol, assetType: AssetType.stock),
              )
            else
              TextField(
                controller: _cryptoController,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                enabled: !_isSubmitting,
                decoration: const InputDecoration(
                  labelText: 'Símbolo de la cripto',
                  hintText: 'ej: BTC-USD, ETH-USD',
                  helperText:
                      'Las criptos no cotizan en una bolsa de acciones.',
                ),
                onSubmitted: (value) => _submitCrypto(),
              ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _isSubmitting ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        // Solo el modo cripto necesita un botón de confirmar: en el de acciones, tocar un
        // resultado del buscador ya es la confirmación.
        if (_assetType == AssetType.crypto)
          FilledButton(
            onPressed: _isSubmitting ? null : _submitCrypto,
            child: _isSubmitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Agregar'),
          ),
      ],
    );
  }

  void _submitCrypto() {
    final ticker = _cryptoController.text.trim();
    if (ticker.isEmpty) {
      setState(() => _errorMessage = 'Ingresá un símbolo.');
      return;
    }
    _submit(ticker: ticker, assetType: AssetType.crypto);
  }
}

class _StockSearch extends StatelessWidget {
  const _StockSearch({
    required this.filterExchange,
    required this.isSubmitting,
    required this.onPicked,
  });

  final ExchangeType? filterExchange;
  final bool isSubmitting;
  final ValueChanged<String> onPicked;

  @override
  Widget build(BuildContext context) {
    if (isSubmitting) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (filterExchange != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Buscando solo en ${filterExchange!.displayName} '
              '(la bolsa que elegiste arriba).',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
          ),
        TickerSearchField(
          filterExchange: filterExchange,
          onSelected: (ticker) => onPicked(ticker.symbol),
        ),
      ],
    );
  }
}
