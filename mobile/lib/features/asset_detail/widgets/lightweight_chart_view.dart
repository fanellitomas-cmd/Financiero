import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/theme/app_theme.dart';

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
///
/// `webview_flutter` solo declara implementación para android/ios/macos: en Web, Linux y
/// Windows no hay plataforma que monte el WebView y `WebViewWidget` termina pintando un
/// bloque gris claro sin estilo que además ignora el alto del padre. Por eso acá se decide
/// primero si la plataforma lo soporta y, si no, se muestra un placeholder con el tema en vez
/// de un rectángulo roto — es la misma degradación explícita que el resto de la app.
class LightweightChartView extends StatelessWidget {
  const LightweightChartView({super.key, required this.candles});

  final List<Candle> candles;

  /// Plataformas donde `webview_flutter` tiene implementación registrada.
  static bool get isSupportedPlatform {
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.macOS =>
        true,
      _ => false,
    };
  }

  @override
  Widget build(BuildContext context) {
    if (!isSupportedPlatform) return const _ChartUnavailable();
    return _WebViewChart(candles: candles);
  }
}

class _ChartUnavailable extends StatelessWidget {
  const _ChartUnavailable();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: AppTheme.border),
      ),
      child: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.candlestick_chart_outlined,
                  size: 36, color: AppTheme.textMuted),
              SizedBox(height: 12),
              Text(
                'El gráfico de velas se ve en la app móvil.\n'
                'Falta una implementación de chart para esta plataforma.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WebViewChart extends StatefulWidget {
  const _WebViewChart({required this.candles});

  final List<Candle> candles;

  @override
  State<_WebViewChart> createState() => _WebViewChartState();
}

class _WebViewChartState extends State<_WebViewChart> {
  late final WebViewController _controller;
  bool _pageLoaded = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppTheme.background)
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
  void didUpdateWidget(covariant _WebViewChart oldWidget) {
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
