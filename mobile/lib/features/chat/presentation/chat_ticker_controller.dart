import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../asset_detail/presentation/selected_asset_controller.dart';

/// Sobre qué activo está conversando el chat. `null` = pregunta general de mercado, que el
/// backend responde con el contexto de alzas y bajas de la jornada
/// (`ChatService._build_general_content`).
///
/// Es estado propio del chat y NO una lectura directa de `selectedAssetProvider`, aunque se
/// alimente de él: si el chat leyera esa selección, desvincular el ticker acá también vaciaría
/// el panel de detalle del master-detail — un efecto lateral sobre otra pantalla que el usuario
/// no pidió.
///
/// La regla de adopción es la que se espera al usarlo: elegir un activo en la Watchlist o en el
/// heatmap pasa la conversación a ese activo; desvincular vuelve a general y **se respeta** hasta
/// que llegue una selección nueva (no se re-adopta la misma en el siguiente rebuild).
class ChatTickerController extends StateNotifier<String?> {
  ChatTickerController(super.initialTicker);

  /// Llamado cuando cambia la selección global de activo.
  void adoptFromSelection(String ticker) => state = ticker;

  /// Elección manual desde el selector de la cabecera del chat.
  void select(String ticker) => state = ticker;

  /// Vuelve a preguntas generales de mercado.
  void unlink() => state = null;
}

final chatTickerProvider =
    StateNotifierProvider<ChatTickerController, String?>((ref) {
  // Se siembra con la selección actual: si el usuario abrió un activo antes de entrar al chat,
  // la conversación arranca sobre ese activo sin que tenga que elegirlo de nuevo.
  final controller = ChatTickerController(
    ref.read(selectedAssetProvider)?.ticker,
  );

  // `listen` y no `watch`: con `watch` este provider se reconstruiría entero ante cada cambio de
  // selección, perdiendo el `unlink()` que el usuario acaba de hacer. Acá solo se empuja el
  // ticker nuevo al controller, que conserva su identidad.
  ref.listen<SelectedAsset?>(selectedAssetProvider, (previous, next) {
    if (next != null && next.ticker != previous?.ticker) {
      controller.adoptFromSelection(next.ticker);
    }
  });

  return controller;
});
