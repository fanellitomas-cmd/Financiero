import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../tickers/presentation/ticker_search_field.dart';
import '../widgets/corporate_news_tab.dart';
import '../widgets/earnings_calendar_tab.dart';
import '../widgets/earnings_history_tab.dart';
import '../widgets/filings_tab.dart';
import 'corporate_controller.dart';

/// Hub Corporativo: cuatro vistas sobre la vida corporativa de las empresas.
///
///   - **Calendario** — quién reporta y cuándo, en una ventana de fechas (todo el mercado).
///   - **Histórico** — qué tan seguido un símbolo le pega a la estimación.
///   - **Reportes** — la biblioteca de presentaciones ante la SEC de un símbolo.
///   - **Noticias** — el feed de novedades y rumores, clasificado por categoría y sentimiento.
///
/// Las cuatro pestañas tienen **fuentes y degradaciones independientes**, y por eso son pestañas y no
/// secciones de una misma página: sin credenciales del buscador de noticias el feed queda vacío, y el
/// calendario sigue funcionando. Anidarlas dejaría que la falla de una escondiera a las otras tres.
///
/// El selector de símbolo es compartido por Histórico y Reportes y vive ACÁ, arriba de las pestañas:
/// quien acaba de ver que NVDA superó cuatro trimestres y pasa a los reportes está siguiendo la misma
/// pregunta sobre la misma empresa, y hacerle tipear el símbolo dos veces rompe ese hilo.
class CorporateHubScreen extends ConsumerStatefulWidget {
  const CorporateHubScreen({super.key});

  @override
  ConsumerState<CorporateHubScreen> createState() => _CorporateHubScreenState();
}

class _CorporateHubScreenState extends ConsumerState<CorporateHubScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  /// Las dos pestañas que dependen del símbolo elegido. Se usa para mostrar el selector solo en
  /// ellas: en el calendario (que es de todo el mercado) y en las noticias (que tienen su propio
  /// filtro) un selector de símbolo arriba sería un control que no hace nada.
  static const _tickerScopedTabs = {1, 2};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    // El selector aparece y desaparece según la pestaña, así que hay que reconstruir al cambiarla.
    _tabController.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    setState(() {});
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showTickerPicker = _tickerScopedTabs.contains(_tabController.index);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hub Corporativo'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'Calendario', icon: Icon(Icons.event_outlined, size: 18)),
            Tab(text: 'Histórico', icon: Icon(Icons.history_outlined, size: 18)),
            Tab(text: 'Reportes', icon: Icon(Icons.description_outlined, size: 18)),
            Tab(text: 'Noticias', icon: Icon(Icons.newspaper_outlined, size: 18)),
          ],
        ),
      ),
      body: Column(
        children: [
          if (showTickerPicker) const _CorporateTickerPicker(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: const [
                EarningsCalendarTab(),
                EarningsHistoryTab(),
                FilingsTab(),
                CorporateNewsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Selector del símbolo que miran Histórico y Reportes.
///
/// Busca sobre el catálogo local (`TickerSearchField`) y no acepta texto libre: tipear un símbolo
/// inexistente devolvería una biblioteca vacía indistinguible de "esta empresa no presenta reportes",
/// que es exactamente la ambigüedad que el resto del módulo se ocupa de evitar.
///
/// El buscador se abre en un diálogo en vez de vivir embebido en la barra porque se autoenfoca y
/// dibuja su propia lista de resultados: inline, robaría el foco del teclado al entrar a la pestaña y
/// dejaría un panel de sugerencias permanente arriba del contenido.
class _CorporateTickerPicker extends ConsumerWidget {
  const _CorporateTickerPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ticker = ref.watch(corporateTickerProvider);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: Row(
        children: [
          const Icon(Icons.business_center_outlined,
              size: 16, color: AppTheme.accent),
          const SizedBox(width: 8),
          if (ticker == null)
            const Expanded(
              child: Text(
                'Ninguna empresa elegida',
                style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
              ),
            )
          else
            Expanded(
              child: Row(
                children: [
                  Text(ticker, style: AppTheme.tickerSymbol.copyWith(fontSize: 15)),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.close, size: 15),
                    tooltip: 'Quitar la empresa elegida',
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        ref.read(corporateTickerProvider.notifier).state = null,
                  ),
                ],
              ),
            ),
          OutlinedButton.icon(
            onPressed: () => CorporateTickerDialog.show(context, ref),
            icon: const Icon(Icons.search, size: 15),
            label: Text(
              ticker == null ? 'Elegir empresa' : 'Cambiar',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// El diálogo de búsqueda del símbolo del Hub.
///
/// Público para que la Ficha del activo no lo necesite (ahí el símbolo ya está dado) pero sí puedan
/// usarlo los tests, que es donde importa poder abrirlo sin pasar por el gesto.
class CorporateTickerDialog extends StatelessWidget {
  const CorporateTickerDialog({super.key, required this.onSelected});

  final ValueChanged<String> onSelected;

  static Future<void> show(BuildContext context, WidgetRef ref) {
    return showDialog<void>(
      context: context,
      builder: (_) => CorporateTickerDialog(
        onSelected: (symbol) =>
            ref.read(corporateTickerProvider.notifier).state = symbol,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Elegir empresa'),
      content: SizedBox(
        width: 380,
        child: TickerSearchField(
          onSelected: (ticker) {
            onSelected(ticker.symbol);
            Navigator.of(context).pop();
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}
