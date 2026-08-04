import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class Candle {
  const Candle({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
  });

  /// Unix timestamp en SEGUNDOS (formato que espera Lightweight Charts), no milisegundos.
  final int time;
  final double open;
  final double high;
  final double low;
  final double close;

  Map<String, dynamic> toJson() =>
      {'time': time, 'open': open, 'high': high, 'low': low, 'close': close};
}

/// Envuelve Lightweight Charts (TradingView) — es una librería JS, así que se embebe vía
/// `webview_flutter` cargando `assets/charts/lightweight_chart.html` y empujando los datos
/// con `runJavaScript` en vez de re-renderizar el HTML en cada actualización.
class LightweightChartView extends StatefulWidget {
  const LightweightChartView({super.key, required this.candles});

  final List<Candle> candles;

  @override
  State<LightweightChartView> createState() => _LightweightChartViewState();
}

class _LightweightChartViewState extends State<LightweightChartView> {
  late final WebViewController _controller;
  bool _pageLoaded = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0B0F14))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _pageLoaded = true;
            _pushData();
          },
        ),
      )
      ..loadFlutterAsset('assets/charts/lightweight_chart.html');
  }

  @override
  void didUpdateWidget(covariant LightweightChartView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_pageLoaded && oldWidget.candles != widget.candles) {
      _pushData();
    }
  }

  void _pushData() {
    final payload =
        jsonEncode(widget.candles.map((candle) => candle.toJson()).toList());
    _controller.runJavaScript('window.setSeriesData($payload);');
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
