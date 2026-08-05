import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/app_theme.dart';
import '../data/nl_search_result.dart';
import '../presentation/nl_search_controller.dart';
import 'nl_search_results.dart';

/// Búsqueda conversacional: el usuario escribe lo que busca en lenguaje natural ("tecnológicas
/// baratas y sin mucha deuda") y el backend lo traduce a criterios y filtra su catálogo.
///
/// Es una hoja aparte y no una pestaña del buscador incremental porque las dos búsquedas tienen
/// costos y ritmos distintos: la del catálogo corre a cada tecla contra la base local, esta se
/// dispara al enviar y gasta una llamada al modelo más una al proveedor de fundamentales por
/// símbolo. Meterlas en el mismo campo haría que escribir una frase disparase cinco búsquedas
/// caras.
///
/// En pantalla ancha va como diálogo acotado (el ancho de lectura de la interpretación y de las
/// razones de coincidencia manda); en mobile como bottom sheet casi completo.
class NlSearchSheet extends ConsumerStatefulWidget {
  const NlSearchSheet({super.key, this.onOpenTicker});

  /// Qué hacer al tocar un resultado. Lo decide quien abre la hoja: desde el Dashboard llena el
  /// panel de detalle, desde la Watchlist navega a la Ficha.
  final ValueChanged<NlTickerMatch>? onOpenTicker;

  static Future<void> show(
    BuildContext context, {
    ValueChanged<NlTickerMatch>? onOpenTicker,
  }) {
    if (context.isDesktop) {
      return showDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620, maxHeight: 780),
            child: NlSearchSheet(onOpenTicker: onOpenTicker),
          ),
        ),
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.92,
        child: NlSearchSheet(onOpenTicker: onOpenTicker),
      ),
    );
  }

  @override
  ConsumerState<NlSearchSheet> createState() => _NlSearchSheetState();
}

class _NlSearchSheetState extends ConsumerState<NlSearchSheet> {
  final _inputController = TextEditingController();

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  void _submit() => ref
      .read(nlSearchControllerProvider.notifier)
      .submit(_inputController.text);

  void _searchExample(String example) {
    _inputController.text = example;
    _submit();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(nlSearchControllerProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SheetHeader(onClose: () => Navigator.of(context).maybePop()),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: _QueryField(
            controller: _inputController,
            isLoading: state.isLoading,
            onSubmit: _submit,
          ),
        ),
        const Divider(height: 1, color: AppTheme.border),
        Expanded(
          child: NlSearchResultsView(
            state: state,
            onOpenTicker: widget.onOpenTicker,
            onExampleTapped: _searchExample,
          ),
        ),
      ],
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 10),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome, size: 20, color: AppTheme.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Buscar con tus palabras',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Text(
                  'Describí qué buscás; el agente lo traduce a filtros sobre el catálogo.',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Cerrar',
            onPressed: onClose,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

class _QueryField extends StatelessWidget {
  const _QueryField({
    required this.controller,
    required this.isLoading,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool isLoading;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: true,
      // `TextInputAction.search` y `onSubmitted`: la búsqueda se dispara al enviar, nunca al
      // tipear. Cada consulta cuesta una llamada al modelo, así que las intermedias serían
      // búsquedas que nadie hizo.
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => onSubmit(),
      maxLength: 500,
      decoration: InputDecoration(
        hintText: 'ej: tecnológicas grandes con poca deuda',
        prefixIcon: const Icon(Icons.search),
        // El contador de 500 caracteres es ruido: nadie escribe una consulta conversacional cerca
        // del límite, y ocupa una línea permanente debajo del campo.
        counterText: '',
        suffixIcon: isLoading
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : IconButton(
                tooltip: 'Buscar',
                icon: const Icon(Icons.arrow_forward),
                onPressed: onSubmit,
              ),
      ),
    );
  }
}
