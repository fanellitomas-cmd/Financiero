import 'package:financiero_app/core/theme/app_theme.dart';
import 'package:financiero_app/features/asset_detail/presentation/selected_asset_controller.dart';
import 'package:financiero_app/features/chat/presentation/chat_screen.dart';
import 'package:financiero_app/features/chat/presentation/chat_ticker_controller.dart';
import 'package:financiero_app/features/watchlist/data/watchlist_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SelectedAsset _asset(String ticker) =>
    SelectedAsset(ticker: ticker, assetType: AssetType.stock);

void main() {
  group('chatTickerProvider', () {
    test('arranca sin ticker cuando no hay nada seleccionado', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(chatTickerProvider), isNull);
    });

    test('se siembra con la selección que ya existía', () {
      // Si el usuario abrió un activo antes de entrar al chat, la conversación arranca sobre ese
      // activo sin que lo tenga que elegir otra vez.
      final container = ProviderContainer(
        overrides: [
          selectedAssetProvider.overrideWith((ref) => _asset('NVDA')),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(chatTickerProvider), 'NVDA');
    });

    test('adopta una selección nueva hecha después', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Se lee primero para que el provider (y su `listen`) queden activos.
      expect(container.read(chatTickerProvider), isNull);

      container.read(selectedAssetProvider.notifier).state = _asset('AAPL');
      expect(container.read(chatTickerProvider), 'AAPL');
    });

    test('desvincular respeta la decisión y no re-adopta la misma selección',
        () {
      // El punto del diseño: `unlink()` no puede ser revertido por el próximo rebuild. Si el chat
      // leyera `selectedAssetProvider` directo, esto volvería a NVDA solo.
      final container = ProviderContainer(
        overrides: [
          selectedAssetProvider.overrideWith((ref) => _asset('NVDA')),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(chatTickerProvider), 'NVDA');

      container.read(chatTickerProvider.notifier).unlink();
      expect(container.read(chatTickerProvider), isNull);

      // Un read más (equivalente a un rebuild de la pantalla) no lo revive.
      expect(container.read(chatTickerProvider), isNull);
    });

    test('una selección nueva sí vuelve a vincular después de desvincular', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(chatTickerProvider);
      container.read(selectedAssetProvider.notifier).state = _asset('NVDA');
      expect(container.read(chatTickerProvider), 'NVDA');

      container.read(chatTickerProvider.notifier).unlink();
      expect(container.read(chatTickerProvider), isNull);

      container.read(selectedAssetProvider.notifier).state = _asset('AAPL');
      expect(container.read(chatTickerProvider), 'AAPL');
    });

    test('desvincular el chat no toca la selección del panel de detalle', () {
      // El chat tiene estado propio justo para esto: desvincular acá no debe vaciar el panel
      // derecho del master-detail, que es otra pantalla.
      final container = ProviderContainer(
        overrides: [
          selectedAssetProvider.overrideWith((ref) => _asset('NVDA')),
        ],
      );
      addTearDown(container.dispose);

      container.read(chatTickerProvider.notifier).unlink();

      expect(container.read(chatTickerProvider), isNull);
      expect(container.read(selectedAssetProvider)?.ticker, 'NVDA');
    });

    test('select() vincula manualmente desde el chip', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(chatTickerProvider.notifier).select('MSFT');
      expect(container.read(chatTickerProvider), 'MSFT');
    });
  });

  group('ChatContextChip', () {
    Future<void> pumpChip(WidgetTester tester, {String? ticker}) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.dark,
            home: Scaffold(body: ChatContextChip(activeTicker: ticker)),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('con ticker dice sobre qué activo se conversa', (tester) async {
      await pumpChip(tester, ticker: 'NVDA');

      expect(find.text('Conversando sobre:'), findsOneWidget);
      expect(find.text('NVDA'), findsOneWidget);
      // La X para desvincular solo existe cuando hay algo que desvincular.
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('sin ticker se presenta como pregunta general', (tester) async {
      await pumpChip(tester);

      expect(find.text('Pregunta general de mercado'), findsOneWidget);
      expect(find.text('Conversando sobre:'), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);
    });

    testWidgets('el símbolo va en monoespaciada y con el color de acento', (
      tester,
    ) async {
      await pumpChip(tester, ticker: 'NVDA');

      final symbol = tester.widget<Text>(find.text('NVDA'));
      expect(symbol.style?.fontFamily, 'AppMono');
      // Cian y no verde/rojo: es un estado activo de la UI, no una señal de mercado.
      expect(symbol.style?.color, AppTheme.accent);
    });

    testWidgets('tocar la X desvincula el ticker', (tester) async {
      late WidgetRef capturedRef;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.dark,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, child) {
                  capturedRef = ref;
                  return ChatContextChip(
                    activeTicker: ref.watch(chatTickerProvider),
                  );
                },
              ),
            ),
          ),
        ),
      );

      capturedRef.read(chatTickerProvider.notifier).select('NVDA');
      await tester.pump();
      expect(find.text('NVDA'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      expect(capturedRef.read(chatTickerProvider), isNull);
      expect(find.text('Pregunta general de mercado'), findsOneWidget);
    });
  });
}
