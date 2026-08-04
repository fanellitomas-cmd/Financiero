import 'dart:async';

import 'package:financiero_app/core/theme/app_theme.dart';
import 'package:financiero_app/features/asset_detail/data/ohlc_data.dart';
import 'package:financiero_app/features/asset_detail/presentation/ticker_history_controller.dart';
import 'package:financiero_app/features/asset_detail/widgets/candlestick_chart_view.dart';
import 'package:financiero_app/features/asset_detail/widgets/ticker_history_chart.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _barJson({
  int t = 1760000000000,
  double o = 100,
  double h = 105,
  double l = 98,
  double c = 103,
  double v = 1000,
}) =>
    {'t': t, 'o': o, 'h': h, 'l': l, 'c': c, 'v': v};

Map<String, dynamic> _historyJson({
  List<Map<String, dynamic>> bars = const [],
  String? degradationReason,
}) =>
    {
      'ticker': 'NVDA',
      'start': '2026-07-05',
      'end': '2026-08-04',
      'bars': bars,
      'degradation_reason': degradationReason,
    };

OhlcBar _bar({
  int msSinceEpoch = 1760000000000,
  double open = 100,
  double high = 105,
  double low = 98,
  double close = 103,
}) =>
    OhlcBar(
      time: DateTime.fromMillisecondsSinceEpoch(msSinceEpoch, isUtc: true),
      open: open,
      high: high,
      low: low,
      close: close,
      volume: 1000,
    );

void main() {
  group('OhlcBar.fromJson', () {
    test('parsea las claves cortas del backend', () {
      final bar = OhlcBar.fromJson(_barJson());

      expect(bar.time.millisecondsSinceEpoch, 1760000000000);
      // UTC explícito: sin `isUtc: true` las etiquetas del eje se correrían según la zona del
      // dispositivo y dos usuarios verían fechas distintas para la misma vela.
      expect(bar.time.isUtc, isTrue);
      expect(bar.open, 100);
      expect(bar.high, 105);
      expect(bar.low, 98);
      expect(bar.close, 103);
      expect(bar.volume, 1000);
    });

    test('isBullish según el cierre contra la apertura', () {
      expect(OhlcBar.fromJson(_barJson(o: 100, c: 103)).isBullish, isTrue);
      expect(OhlcBar.fromJson(_barJson(o: 103, c: 100)).isBullish, isFalse);
      // Una vela plana cuenta como alcista: inventarle un tercer color no aporta nada visual.
      expect(OhlcBar.fromJson(_barJson(o: 100, c: 100)).isBullish, isTrue);
    });

    test('acepta enteros donde el JSON podría no traer decimales', () {
      // El backend serializa floats, pero un 100.0 puede viajar como `100`: castear con `as double`
      // en vez de `as num` reventaría acá.
      final bar = OhlcBar.fromJson(const {
        't': 1000,
        'o': 100,
        'h': 105,
        'l': 98,
        'c': 103,
        'v': 1000,
      });
      expect(bar.open, 100.0);
    });
  });

  group('TickerHistory', () {
    test('parsea la respuesta completa', () {
      final history = TickerHistory.fromJson(
        _historyJson(bars: [_barJson(t: 1000), _barJson(t: 2000)]),
      );

      expect(history.ticker, 'NVDA');
      expect(history.start, DateTime.parse('2026-07-05'));
      expect(history.bars, hasLength(2));
      expect(history.isEmpty, isFalse);
      expect(history.degradationReason, isNull);
    });

    test('un histórico vacío conserva el motivo', () {
      // Es el caso normal cuando el proveedor está caído o sin configurar: el endpoint responde
      // 200, y sin el motivo el chart no podría explicar por qué está vacío.
      final history = TickerHistory.fromJson(
        _historyJson(degradationReason: 'falta POLYGON_API_KEY en .env'),
      );

      expect(history.isEmpty, isTrue);
      expect(history.degradationReason, 'falta POLYGON_API_KEY en .env');
      expect(history.priceRange, isNull);
    });

    test('priceRange usa mínimos y máximos, no los cierres', () {
      // Escalar el eje con los cierres recortaría las mechas, que es justo lo que una vela aporta.
      final history = TickerHistory.fromJson(
        _historyJson(
          bars: [
            _barJson(t: 1000, o: 100, h: 110, l: 95, c: 105),
            _barJson(t: 2000, o: 105, h: 120, l: 90, c: 100),
          ],
        ),
      );

      final range = history.priceRange!;
      expect(range.min, 90);
      expect(range.max, 120);
    });
  });

  group('CandlestickChartView', () {
    Future<void> pumpChart(WidgetTester tester, List<OhlcBar> bars) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: SizedBox(
              height: 260,
              width: 400,
              child: CandlestickChartView(bars: bars),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('dibuja un CandlestickChart nativo, sin WebView', (
      tester,
    ) async {
      // El punto de haber migrado a fl_chart: el chart es Flutter puro y se renderiza igual en
      // web, escritorio y mobile.
      await pumpChart(tester, [
        _bar(msSinceEpoch: 1000),
        _bar(msSinceEpoch: 2000, open: 103, close: 99),
      ]);

      expect(find.byType(CandlestickChart), findsOneWidget);
    });

    testWidgets('pinta cada vela con el color de su dirección', (tester) async {
      await pumpChart(tester, [
        _bar(msSinceEpoch: 1000, open: 100, close: 105), // alcista
        _bar(msSinceEpoch: 2000, open: 105, close: 100), // bajista
      ]);

      final chart = tester.widget<CandlestickChart>(
        find.byType(CandlestickChart),
      );
      final painter =
          chart.data.candlestickPainter as DefaultCandlestickPainter;
      final spots = chart.data.candlestickSpots;

      expect(
        painter.candlestickStyleProvider(spots[0], 0).bodyFillColor,
        AppTheme.bullish,
      );
      expect(
        painter.candlestickStyleProvider(spots[1], 1).bodyFillColor,
        AppTheme.bearish,
      );
    });

    testWidgets('el eje Y deja aire arriba y abajo del rango real', (
      tester,
    ) async {
      await pumpChart(tester, [
        _bar(msSinceEpoch: 1000, low: 90, high: 110),
      ]);

      final chart = tester.widget<CandlestickChart>(
        find.byType(CandlestickChart),
      );
      // Sin margen, la vela más alta y la más baja se leen como recortadas contra el borde.
      expect(chart.data.minY, lessThan(90));
      expect(chart.data.maxY, greaterThan(110));
    });

    testWidgets('un histórico plano no rompe el cálculo de la escala', (
      tester,
    ) async {
      // Span 0 daría una división por cero al calcular los intervalos de la grilla.
      await pumpChart(tester, [
        _bar(msSinceEpoch: 1000, open: 50, high: 50, low: 50, close: 50),
        _bar(msSinceEpoch: 2000, open: 50, high: 50, low: 50, close: 50),
      ]);

      final chart = tester.widget<CandlestickChart>(
        find.byType(CandlestickChart),
      );
      expect(chart.data.maxY, greaterThan(chart.data.minY));
      expect(tester.takeException(), isNull);
    });

    testWidgets('una sola vela se dibuja sin lanzar', (tester) async {
      // El intervalo de etiquetas del eje X se calcula sobre la cantidad de velas; con una sola,
      // un intervalo 0 haría lanzar a fl_chart.
      await pumpChart(tester, [_bar(msSinceEpoch: 1000)]);

      expect(find.byType(CandlestickChart), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('usa el índice como X para no dejar huecos de fin de semana', (
      tester,
    ) async {
      await pumpChart(tester, [
        _bar(msSinceEpoch: 1760000000000),
        // Tres días después: con el timestamp como X quedaría un hueco vacío en el medio.
        _bar(msSinceEpoch: 1760259200000),
      ]);

      final chart = tester.widget<CandlestickChart>(
        find.byType(CandlestickChart),
      );
      expect(chart.data.candlestickSpots.map((spot) => spot.x), [0.0, 1.0]);
    });
  });

  group('TickerHistoryChart', () {
    Future<void> pumpSection(
      WidgetTester tester,
      FutureOr<TickerHistory> Function() result,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tickerHistoryProvider('NVDA').overrideWith((ref) => result()),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const Scaffold(body: TickerHistoryChart(ticker: 'NVDA')),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('con velas muestra el chart y la leyenda del rango', (
      tester,
    ) async {
      await pumpSection(
        tester,
        () => TickerHistory.fromJson(
          _historyJson(bars: [_barJson(t: 1000), _barJson(t: 2000)]),
        ),
      );

      expect(find.byType(CandlestickChart), findsOneWidget);
      expect(find.textContaining('2 ruedas'), findsOneWidget);
      expect(find.textContaining('velas diarias'), findsOneWidget);
    });

    testWidgets('sin velas muestra el motivo del backend', (tester) async {
      await pumpSection(
        tester,
        () => TickerHistory.fromJson(
          _historyJson(degradationReason: 'falta POLYGON_API_KEY en .env'),
        ),
      );

      expect(find.byType(CandlestickChart), findsNothing);
      expect(find.textContaining('falta POLYGON_API_KEY'), findsOneWidget);
      // Sin velas no hay rango que contextualizar.
      expect(find.textContaining('ruedas'), findsNothing);
    });

    testWidgets('sin velas y sin motivo cae en un mensaje genérico', (
      tester,
    ) async {
      await pumpSection(tester, () => TickerHistory.fromJson(_historyJson()));

      expect(find.textContaining('No hay velas históricas'), findsOneWidget);
    });

    testWidgets('un error de red se muestra con opción de reintentar', (
      tester,
    ) async {
      await pumpSection(
        tester,
        () => Future<TickerHistory>.error(StateError('sin conexión')),
      );

      expect(find.text('Reintentar'), findsOneWidget);
    });

    testWidgets('reserva el alto también mientras carga', (tester) async {
      // Sin alto reservado, la Ficha salta de layout cuando el histórico termina de llegar.
      final pending = Completer<TickerHistory>();
      addTearDown(
        () => pending.complete(TickerHistory.fromJson(_historyJson())),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tickerHistoryProvider('NVDA').overrideWith((ref) => pending.future),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const Scaffold(body: TickerHistoryChart(ticker: 'NVDA')),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final box = tester.getSize(
        find
            .ancestor(
              of: find.byType(CircularProgressIndicator),
              matching: find.byType(SizedBox),
            )
            .last,
      );
      expect(box.height, 260);
    });
  });
}
