import 'package:financiero_app/core/providers.dart';
import 'package:financiero_app/core/theme/app_theme.dart';
import 'package:financiero_app/features/settings/data/exchange_type.dart';
import 'package:financiero_app/features/watchlist/data/watchlist_alert_rule.dart';
import 'package:financiero_app/features/watchlist/data/watchlist_alerts_repository.dart';
import 'package:financiero_app/features/watchlist/data/watchlist_models.dart';
import 'package:financiero_app/features/watchlist/presentation/watchlist_alert_config_dialog.dart';
import 'package:financiero_app/features/watchlist/presentation/watchlist_alerts_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests de las reglas de alerta contextuales.
///
/// Los contratos que este bloque promete y que son fáciles de romper sin darse cuenta:
///
///   1. **El cuerpo del request lleva SOLO los campos del tipo.** El backend rechaza los de otro
///      tipo con 422 — mandar `min_severity` en una regla de precio rompe el guardado entero.
///   2. **Sin reglas se recibe todo.** El diálogo lo dice explícito: tres interruptores apagados
///      no significan silencio, significan lo contrario.
///   3. **Una regla apagada que nunca existió no se crea**, para no llenar la tabla de
///      configuración que nadie pidió.
///   4. **Apagar y eliminar son cosas distintas**, y las dos están disponibles.

class _FakeAlertsRepository implements WatchlistAlertsRepository {
  _FakeAlertsRepository({this.existing = const []});

  final List<WatchlistAlertRule> existing;

  final List<(String, Map<String, dynamic>)> created = [];
  final List<(String, Map<String, dynamic>)> updated = [];
  final List<String> removed = [];

  @override
  Future<List<WatchlistAlertRule>> list({
    String? ticker,
    AlertRuleType? alertType,
  }) async =>
      existing;

  @override
  Future<WatchlistAlertRule> create(
    String ticker,
    WatchlistAlertRuleDraft draft,
  ) async {
    final body = draft.toCreateJson(ticker);
    created.add((ticker, body));
    return _rule(id: 'nueva', ticker: ticker, type: draft.alertType);
  }

  @override
  Future<WatchlistAlertRule> update(
    String ruleId,
    WatchlistAlertRuleDraft draft,
  ) async {
    final body = draft.toUpdateJson();
    updated.add((ruleId, body));
    return _rule(id: ruleId, ticker: 'NVDA', type: draft.alertType);
  }

  @override
  Future<void> remove(String ruleId) async => removed.add(ruleId);
}

WatchlistAlertRule _rule({
  String id = 'rule-1',
  String ticker = 'NVDA',
  AlertRuleType type = AlertRuleType.price,
  bool enabled = true,
  double? thresholdPct,
  AlertSeverity? minSeverity,
  bool requireNegativeSentiment = false,
  TrendHorizon? trendHorizon,
  TrendBreakDirection? trendDirection,
  double? minProbabilityPct,
}) =>
    WatchlistAlertRule(
      id: id,
      watchlistItemId: 'item-1',
      ticker: ticker,
      alertType: type,
      enabled: enabled,
      thresholdPct: thresholdPct,
      minSeverity: minSeverity,
      requireNegativeSentiment: requireNegativeSentiment,
      trendHorizon: trendHorizon,
      trendDirection: trendDirection,
      minProbabilityPct: minProbabilityPct,
    );

const _item = WatchlistItem(
  id: 'item-1',
  ticker: 'NVDA',
  assetType: AssetType.stock,
  alertThresholdPct: 8,
  enableBeginnerMode: false,
  exchange: ExchangeType.nasdaq,
);

/// Monta el diálogo ya abierto. El provider de reglas se sobreescribe con la lista que el test
/// quiera; el repositorio falso registra lo que se envía.
Future<void> _pumpDialog(
  WidgetTester tester,
  _FakeAlertsRepository repository, {
  Key? scopeKey,
}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      key: scopeKey,
      overrides: [
        watchlistAlertsRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, child) {
              // Se fuerza la resolución del provider de reglas antes de abrir el diálogo: el
              // diálogo lee el estado ya cargado en `initState`, igual que en la app real (la
              // pantalla de watchlist ya lo tiene resuelto cuando el usuario abre el menú).
              ref.watch(watchlistAlertRulesProvider);
              return TextButton(
                onPressed: () =>
                    WatchlistAlertConfigDialog.show(context, _item),
                child: const Text('abrir'),
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
}

void main() {
  // --- Serialización -----------------------------------------------------------------------

  group('WatchlistAlertRuleDraft', () {
    test('una regla de precio manda solo su umbral', () {
      final body = const WatchlistAlertRuleDraft(
        alertType: AlertRuleType.price,
        thresholdPct: 6.5,
        // Campos de otros tipos presentes en el borrador: el serializador tiene que ignorarlos.
        minSeverity: AlertSeverity.critical,
        trendHorizon: TrendHorizon.largo,
      ).toCreateJson('NVDA');

      expect(body['ticker'], 'NVDA');
      expect(body['alert_type'], 'PRICE');
      expect(body['threshold_pct'], '6.5');
      // El backend responde 422 si llegan: una regla que parece configurada pero cuyo parámetro
      // nadie lee es peor que un error.
      expect(body.containsKey('min_severity'), isFalse);
      expect(body.containsKey('trend_horizon'), isFalse);
    });

    test('una regla de noticias manda severidad y sentimiento, nada más', () {
      final body = const WatchlistAlertRuleDraft(
        alertType: AlertRuleType.newsSeverity,
        minSeverity: AlertSeverity.critical,
        requireNegativeSentiment: true,
        thresholdPct: 5,
      ).toCreateJson('KO');

      expect(body['min_severity'], 'CRITICAL');
      expect(body['require_negative_sentiment'], isTrue);
      expect(body.containsKey('threshold_pct'), isFalse);
    });

    test('una regla de tendencia manda horizonte, dirección y probabilidad',
        () {
      final body = const WatchlistAlertRuleDraft(
        alertType: AlertRuleType.trendBreak,
        trendHorizon: TrendHorizon.corto,
        trendDirection: TrendBreakDirection.cualquiera,
        minProbabilityPct: 65,
        minSeverity: AlertSeverity.high,
      ).toCreateJson('TSLA');

      expect(body['trend_horizon'], 'CORTO');
      expect(body['trend_direction'], 'CUALQUIERA');
      expect(body['min_probability_pct'], '65.0');
      expect(body.containsKey('min_severity'), isFalse);
    });

    test('el PATCH no lleva ticker ni tipo', () {
      // No se pueden cambiar: eso sería otra regla, y dejaría la fila con los parámetros del tipo
      // anterior.
      final body = const WatchlistAlertRuleDraft(
        alertType: AlertRuleType.price,
        thresholdPct: 4,
      ).toUpdateJson();

      expect(body.containsKey('ticker'), isFalse);
      expect(body.containsKey('alert_type'), isFalse);
      expect(body['threshold_pct'], '4.0');
    });

    test('los defaults de precio arrancan del umbral que ya tenía el usuario',
        () {
      // Quien venía usando 8% no debería encontrarse con que se le reseteó al default global.
      final draft = WatchlistAlertRuleDraft.defaults(
        AlertRuleType.price,
        currentThresholdPct: 8,
      );
      expect(draft.thresholdPct, 8);
    });

    test('los defaults contextuales coinciden con los del backend', () {
      final news = WatchlistAlertRuleDraft.defaults(AlertRuleType.newsSeverity);
      final trend = WatchlistAlertRuleDraft.defaults(AlertRuleType.trendBreak);

      expect(news.minSeverity, AlertSeverity.high);
      expect(news.requireNegativeSentiment, isFalse);
      expect(trend.trendHorizon, TrendHorizon.mediano);
      expect(trend.trendDirection, TrendBreakDirection.bajista);
      expect(trend.minProbabilityPct, 50);
    });
  });

  group('WatchlistAlertRule.fromJson', () {
    test('parsea los Decimal que el backend manda como string', () {
      final rule = WatchlistAlertRule.fromJson(const {
        'id': 'r1',
        'watchlist_item_id': 'i1',
        'ticker': 'NVDA',
        'alert_type': 'TREND_BREAK',
        'enabled': true,
        'threshold_pct': null,
        'min_severity': null,
        'require_negative_sentiment': false,
        'trend_horizon': 'MEDIANO',
        'trend_direction': 'BAJISTA',
        'min_probability_pct': '50.00',
      });

      expect(rule.alertType, AlertRuleType.trendBreak);
      expect(rule.minProbabilityPct, 50);
      expect(rule.trendHorizon, TrendHorizon.mediano);
    });

    test('un tipo desconocido no rompe la pantalla', () {
      // Una regla de un tipo que este cliente no conoce se muestra como la más básica en vez de
      // tirar una excepción en medio de la lista.
      expect(alertRuleTypeFromWire('SENTIMENT_SHIFT'), AlertRuleType.price);
    });

    test('el resumen describe la regla sin abrir el formulario', () {
      expect(
        _rule(type: AlertRuleType.price, thresholdPct: 6.5).summary,
        'Variación de ±6.5%',
      );
      expect(
        _rule(
          type: AlertRuleType.newsSeverity,
          minSeverity: AlertSeverity.critical,
          requireNegativeSentiment: true,
        ).summary,
        contains('crítica'),
      );
      expect(
        _rule(
          type: AlertRuleType.trendBreak,
          trendHorizon: TrendHorizon.mediano,
          trendDirection: TrendBreakDirection.bajista,
          minProbabilityPct: 60,
        ).summary,
        contains('mediano plazo'),
      );
    });
  });

  // --- El diálogo ---------------------------------------------------------------------------

  testWidgets('sin reglas avisa que se recibe TODO, no lo contrario', (
    tester,
  ) async {
    await _pumpDialog(tester, _FakeAlertsRepository());

    // Tres interruptores apagados se verían igual que "silenciado" sin este aviso, cuando en
    // realidad significan exactamente lo opuesto.
    expect(
      find.textContaining('recibís TODOS los avisos'),
      findsOneWidget,
    );
    expect(find.text('Por precio'), findsOneWidget);
    expect(find.text('Por noticias'), findsOneWidget);
    expect(find.text('Por tendencia'), findsOneWidget);
  });

  testWidgets('guardar sin activar nada no crea reglas apagadas', (
    tester,
  ) async {
    // Crear tres filas apagadas por cada ticker llenaría la tabla de configuración que nadie
    // pidió, y "sin regla" ya es un estado con significado propio.
    final repository = _FakeAlertsRepository();
    await _pumpDialog(tester, repository);

    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();

    expect(repository.created, isEmpty);
    expect(repository.updated, isEmpty);
  });

  testWidgets('activar la regla de precio la crea con el umbral del item', (
    tester,
  ) async {
    final repository = _FakeAlertsRepository();
    await _pumpDialog(tester, repository);

    // El primer switch del diálogo es el de la regla de precio.
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();

    expect(repository.created, hasLength(1));
    final (ticker, body) = repository.created.single;
    expect(ticker, 'NVDA');
    expect(body['alert_type'], 'PRICE');
    // 8.0 es el umbral que el item ya tenía, no el default global de 3.
    expect(body['threshold_pct'], '8.0');
    expect(body['enabled'], isTrue);
  });

  testWidgets('el formulario muestra los parámetros de la regla ya guardada', (
    tester,
  ) async {
    await _pumpDialog(
      tester,
      _FakeAlertsRepository(
        existing: [
          _rule(
            id: 'r-trend',
            type: AlertRuleType.trendBreak,
            trendHorizon: TrendHorizon.corto,
            trendDirection: TrendBreakDirection.alcista,
            minProbabilityPct: 70,
          ),
        ],
      ),
    );

    expect(find.text('Corto (1-14 días)'), findsOneWidget);
    expect(find.text('Se da vuelta a favor'), findsOneWidget);
    expect(find.text('70%'), findsOneWidget);
    // Con una regla ya activa, el aviso de arriba cambia de sentido.
    expect(find.textContaining('Solo vas a recibir avisos'), findsOneWidget);
  });

  testWidgets('apagar una regla existente la actualiza en vez de borrarla', (
    tester,
  ) async {
    // Apagar conserva los parámetros ajustados; eliminar es otro gesto y tiene su propio botón.
    final repository = _FakeAlertsRepository(
      existing: [
        _rule(id: 'r-precio', type: AlertRuleType.price, thresholdPct: 6.5),
      ],
    );
    await _pumpDialog(tester, repository);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();

    expect(repository.removed, isEmpty);
    expect(repository.updated, hasLength(1));
    final (ruleId, body) = repository.updated.single;
    expect(ruleId, 'r-precio');
    expect(body['enabled'], isFalse);
    expect(body['threshold_pct'], '6.5');
  });

  testWidgets('eliminar una regla la borra del backend', (tester) async {
    final repository = _FakeAlertsRepository(
      existing: [
        _rule(id: 'r-precio', type: AlertRuleType.price, thresholdPct: 6.5),
      ],
    );
    await _pumpDialog(tester, repository);

    await tester.tap(find.text('Eliminar regla'));
    await tester.pumpAndSettle();

    expect(repository.removed, ['r-precio']);
  });

  testWidgets('la severidad baja no se ofrece, pero una ya guardada se respeta',
      (tester) async {
    // Una regla con severidad mínima baja no filtra nada, así que ofrecerla sería ofrecer una
    // configuración inútil. Pero si existe (creada por API), el desplegable tiene que poder
    // mostrarla sin romperse.
    await _pumpDialog(
      tester,
      _FakeAlertsRepository(
        existing: [
          _rule(
            id: 'r-news',
            type: AlertRuleType.newsSeverity,
            minSeverity: AlertSeverity.low,
          ),
        ],
      ),
      scopeKey: const ValueKey('con-baja'),
    );

    expect(find.text('Baja'), findsOneWidget);
  });
}
