import 'package:dio/dio.dart';
import 'package:financiero_app/core/providers.dart';
import 'package:financiero_app/core/theme/app_theme.dart';
import 'package:financiero_app/features/asset_detail/data/deep_intelligence.dart';
import 'package:financiero_app/features/asset_detail/data/intelligence_note_snippet.dart';
import 'package:financiero_app/features/asset_detail/presentation/deep_intelligence_controller.dart';
import 'package:financiero_app/features/asset_detail/widgets/ticker_notes_tab.dart';
import 'package:financiero_app/features/lab/data/note.dart';
import 'package:financiero_app/features/lab/data/notes_repository.dart';
import 'package:financiero_app/features/lab/widgets/markdown_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests de la integración Ficha de activo ↔ Investment Lab.
///
/// Lo que esta integración promete y que es fácil de romper sin darse cuenta:
///
///   1. **El vínculo es el `ticker`, no la carpeta.** Una nota de NVDA archivada en
///      "Semiconductores" y otra suelta en la raíz aparecen las dos en la pestaña del activo. Si la
///      vinculación dependiera de la carpeta, organizar el Lab rompería esta pantalla.
///   2. **El bloque insertado es una transcripción, no un resumen generado.** Todo lo que sale del
///      compositor son datos que la Ficha ya está mostrando; pedirle al modelo un resumen del resumen
///      sería una oportunidad más de inventar un número.
///   3. **Lo que falta se declara.** Un bloque sin datos deja constancia en la nota en vez de
///      desaparecer: una nota que copió solo lo que había se lee, meses después, como si eso fuera
///      todo lo que se sabía.
///   4. **Agregar la Ficha a una nota existente AGREGA, nunca reemplaza.** El cuerpo actual puede ser
///      la tesis escrita a mano; los datos de la Ficha se pueden regenerar, esa no.

// --- Dobles ------------------------------------------------------------------------------------

class _FakeNotesRepository implements NotesRepository {
  _FakeNotesRepository({this.page = NotePage.empty, this.note});

  NotePage page;
  Note? note;
  Object? failure;

  final List<Map<String, Object?>> listQueries = [];
  final List<NoteDraft> createdDrafts = [];
  final List<(String, NoteDraft)> savedDrafts = [];

  @override
  Future<NotePage> list({
    String? folderId,
    bool rootOnly = false,
    String? ticker,
    String? query,
    int limit = 50,
    int offset = 0,
    CancelToken? cancelToken,
  }) async {
    listQueries.add({'folderId': folderId, 'ticker': ticker, 'query': query});
    return page;
  }

  @override
  Future<Note> get(String noteId) async => note ?? _note(id: noteId);

  @override
  Future<Note> create(NoteDraft draft) async {
    if (failure != null) throw failure!;
    createdDrafts.add(draft);
    return _note(id: 'creada', title: draft.effectiveTitle, content: draft.content);
  }

  @override
  Future<Note> update(
    String noteId, {
    String? title,
    String? content,
    bool? pinned,
    FieldUpdate<String>? folderId,
    FieldUpdate<String>? ticker,
  }) async =>
      note ?? _note(id: noteId);

  @override
  Future<Note> save(String noteId, NoteDraft draft) async {
    if (failure != null) throw failure!;
    savedDrafts.add((noteId, draft));
    return _note(id: noteId, title: draft.effectiveTitle, content: draft.content);
  }

  @override
  Future<void> remove(String noteId) async {}
}

// --- Fixtures ----------------------------------------------------------------------------------

Note _note({
  required String id,
  String title = 'Tesis NVDA',
  String content = 'Mi lectura propia del activo.',
  String? ticker = 'NVDA',
  bool pinned = false,
}) =>
    Note(
      id: id,
      folderId: null,
      ticker: ticker,
      title: title,
      content: content,
      pinned: pinned,
      createdAt: DateTime.utc(2026, 8, 1, 10),
      updatedAt: DateTime.utc(2026, 8, 5, 10),
    );

NoteSummary _summary({
  required String id,
  String title = 'Tesis NVDA',
  String excerpt = 'Mi lectura propia…',
  int contentLength = 300,
  String? folderId,
  bool pinned = false,
}) =>
    NoteSummary(
      id: id,
      folderId: folderId,
      ticker: 'NVDA',
      title: title,
      pinned: pinned,
      createdAt: DateTime.utc(2026, 8, 1, 10),
      updatedAt: DateTime.utc(2026, 8, 5, 10),
      excerpt: excerpt,
      contentLength: contentLength,
    );

Map<String, dynamic> _ratio(String label, double? value, String? unit) =>
    {'label': label, 'value': value, 'unit': unit};

DeepIntelligence _intelligence({
  String fundamentalsAvailability = 'AVAILABLE',
  String ragAvailability = 'AVAILABLE',
  String projectionsAvailability = 'AVAILABLE',
  String? fundamentalsReason,
  String? ragReason,
  String? projectionsReason,
  double? baseProbability = 55,
}) =>
    DeepIntelligence.fromJson({
      'ticker': 'NVDA',
      'company_name': 'NVIDIA Corporation',
      'generated_at': '2026-08-04T21:00:00Z',
      'fundamentals': {
        'availability': fundamentalsAvailability,
        'as_of': '2026-08-04T00:00:00Z',
        'period': 'TTM',
        'price_earnings': _ratio(
          'P/E',
          fundamentalsAvailability == 'AVAILABLE' ? 58.4 : null,
          'x',
        ),
        'gross_margin_pct': _ratio(
          'Margen bruto',
          fundamentalsAvailability == 'AVAILABLE' ? 0.749 : null,
          '%',
        ),
        'financial_health':
            fundamentalsAvailability == 'AVAILABLE' ? 'SOLIDA' : 'INDETERMINADA',
        'financial_health_notes': fundamentalsAvailability == 'AVAILABLE'
            ? ['Deuda/Equity de 0.42x: apalancamiento bajo.']
            : <String>[],
        'degradation_reason': fundamentalsReason,
      },
      'rag_summary': {
        'availability': ragAvailability,
        'headline':
            ragAvailability == 'AVAILABLE' ? 'Trimestre récord.' : null,
        'key_points': ragAvailability == 'AVAILABLE'
            ? ['Ingresos +114% YoY.', 'Margen bruto en 74,9%.']
            : <String>[],
        'risks': ragAvailability == 'AVAILABLE'
            ? ['Restricciones de exportación en evaluación.']
            : <String>[],
        'sources': ragAvailability == 'AVAILABLE'
            ? [
                {
                  'ref_id': 'NEWS-1',
                  'source_type': 'NEWS',
                  'title': 'NVDA reporta ingresos récord',
                  'url': 'https://news.example/1',
                  'published_at': '2026-08-01T20:05:00Z',
                },
              ]
            : <Map<String, dynamic>>[],
        'degradation_reason': ragReason,
      },
      'projections': {
        'availability': projectionsAvailability,
        'short_term': projectionsAvailability == 'AVAILABLE'
            ? {
                'horizon_label': 'Corto plazo (1-14 días)',
                'trend': 'ALCISTA',
                'confidence': 'MEDIA',
                'argument': 'El guidance revisado al alza es un catalizador.',
                'evidence_refs': ['NEWS-1'],
              }
            : null,
        'medium_term': projectionsAvailability == 'AVAILABLE'
            ? {
                'horizon_label': 'Mediano plazo (1-6 meses)',
                'base_case': {
                  'label': 'BASE',
                  'narrative': 'Sostiene márgenes.',
                  'probability_pct': baseProbability,
                },
                'bull_case': {
                  'label': 'ALCISTA',
                  'narrative': 'Acelera por demanda.',
                  'probability_pct': 25,
                },
                'bear_case': {
                  'label': 'BAJISTA',
                  'narrative': 'Compresión de múltiplos.',
                  'probability_pct': 20,
                },
                'catalysts': ['Resultados del Q3'],
                'confidence': 'MEDIA',
                'evidence_refs': ['NEWS-1'],
              }
            : null,
        'long_term': projectionsAvailability == 'AVAILABLE'
            ? {
                'horizon_label': 'Largo plazo (1-3 años)',
                'thesis': 'Foso tecnológico en el ecosistema de software.',
                'conviction': 'MODERADA',
                'supporting_factors': ['Escala de I+D.'],
                'invalidation_triggers': ['Adopción de arquitectura abierta.'],
                'evidence_refs': ['SEC_10K-1'],
              }
            : null,
        'degradation_reason': projectionsReason,
      },
      'served_from_cache': false,
    });

Future<void> _pumpTab(
  WidgetTester tester, {
  required _FakeNotesRepository notes,
  DeepIntelligence? intelligence,
  Size size = const Size(1000, 1800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        notesRepositoryProvider.overrideWithValue(notes),
        if (intelligence != null)
          deepIntelligenceProvider('NVDA').overrideWith((ref) => intelligence),
      ],
      child: MaterialApp(
        theme: AppTheme.dark,
        home: const Scaffold(body: TickerNotesTab(ticker: 'NVDA')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // --- Compositor del bloque de la Ficha ------------------------------------------------------

  group('buildIntelligenceNoteMarkdown', () {
    test('transcribe los tres bloques con su encabezado y la fecha', () {
      final markdown = buildIntelligenceNoteMarkdown(_intelligence());

      expect(markdown, contains('## $kIntelligenceSnippetHeading — NVDA'));
      expect(markdown, contains('NVIDIA Corporation'));
      // La fecha de generación va arriba y siempre: una tesis pegada hace ocho meses y una de ayer se
      // leen igual dentro del cuerpo de una nota, y confundirlas es el error más caro posible acá.
      expect(markdown, contains('04/08/2026'));
      expect(markdown, contains('### Fundamentales'));
      expect(markdown, contains('### Síntesis de reportes'));
      expect(markdown, contains('### Proyecciones'));
    });

    test('copia los ratios con el formato de la Ficha, no el número crudo', () {
      final markdown = buildIntelligenceNoteMarkdown(_intelligence());

      expect(markdown, contains('Salud financiera: **Sólida**'));
      expect(markdown, contains('P/E: `58.40x`'));
      // El 0.749 se normaliza a 74,90%: pegar "0.749%" en una nota sería copiar un dato mal.
      expect(markdown, contains('Margen bruto: `74.90%`'));
    });

    test('copia la síntesis con sus riesgos y sus fuentes', () {
      final markdown = buildIntelligenceNoteMarkdown(_intelligence());

      expect(markdown, contains('**Trimestre récord.**'));
      expect(markdown, contains('- Ingresos +114% YoY.'));
      expect(markdown, contains('**Riesgos señalados:**'));
      expect(markdown, contains('Restricciones de exportación'));
      // Las fuentes son lo que hace verificable la síntesis DENTRO de la nota: sin ellas el texto
      // pegado queda como una afirmación sin respaldo.
      expect(markdown, contains('_Fuentes: NEWS-1._'));
    });

    test('conserva lo que invalidaría la tesis de largo plazo', () {
      final markdown = buildIntelligenceNoteMarkdown(_intelligence());

      // Es la parte que más importa guardar: es contra qué se va a chequear la posición en tres
      // meses.
      expect(markdown, contains('**Qué invalidaría la tesis:**'));
      expect(markdown, contains('Adopción de arquitectura abierta.'));
      expect(markdown, contains('**Catalizadores:** Resultados del Q3'));
    });

    test('un escenario sin probabilidad no inventa un 0%', () {
      final markdown = buildIntelligenceNoteMarkdown(
        _intelligence(baseProbability: null),
      );

      expect(markdown, contains('- BASE: Sostiene márgenes.'));
      expect(markdown, isNot(contains('BASE (0%)')));
      // Los otros dos sí tienen número y lo conservan.
      expect(markdown, contains('- ALCISTA (25%)'));
    });

    test('un bloque sin datos deja constancia con su motivo', () {
      final markdown = buildIntelligenceNoteMarkdown(
        _intelligence(
          fundamentalsAvailability: 'UNAVAILABLE',
          fundamentalsReason: 'Falta la credencial de FMP',
        ),
      );

      // Se declara, no se omite: si no, la nota se leería como si eso fuera todo lo que se sabía.
      expect(markdown, contains('Sin datos de fundamentales'));
      expect(markdown, contains('Falta la credencial de FMP'));
      expect(markdown, isNot(contains('P/E:')));
    });

    test('los tres bloques caídos igual producen una nota legible', () {
      final markdown = buildIntelligenceNoteMarkdown(
        _intelligence(
          fundamentalsAvailability: 'UNAVAILABLE',
          ragAvailability: 'UNAVAILABLE',
          projectionsAvailability: 'UNAVAILABLE',
        ),
      );

      expect(markdown, contains('Sin datos de fundamentales'));
      expect(markdown, contains('Sin síntesis disponible'));
      expect(markdown, contains('Sin proyecciones disponibles'));
      // Y el descargo sigue estando: la nota no puede quedar como si fuera asesoramiento.
      expect(markdown, contains('no es asesoramiento financiero'));
    });

    test('el resultado es Markdown que el visor de la app sabe leer', () {
      // No alcanza con que el texto esté: si el compositor emitiera una sintaxis que el visor no
      // soporta, la nota se vería como un volcado plano.
      final blocks =
          parseMarkdownBlocks(buildIntelligenceNoteMarkdown(_intelligence()));

      expect(
        blocks.map((block) => block.kind),
        contains(MarkdownBlockKind.heading2),
      );
      expect(
        blocks.map((block) => block.kind),
        contains(MarkdownBlockKind.heading3),
      );
      expect(blocks.map((block) => block.kind), contains(MarkdownBlockKind.bullet));
      expect(blocks.map((block) => block.kind), contains(MarkdownBlockKind.rule));

      // El aviso de un bloque caído sale como cita, que es cómo el visor lo destaca del resto del
      // texto — si no, "sin datos" se leería como una afirmación más de la nota.
      final degraded = parseMarkdownBlocks(
        buildIntelligenceNoteMarkdown(
          _intelligence(fundamentalsAvailability: 'UNAVAILABLE'),
        ),
      );
      expect(
        degraded.map((block) => block.kind),
        contains(MarkdownBlockKind.quote),
      );
    });
  });

  group('intelligenceNoteDraft', () {
    test('titula con el símbolo y la fecha, y vincula el ticker', () {
      final draft = intelligenceNoteDraft(_intelligence());

      // Tres "Ficha de NVDA" sin fecha son indistinguibles en el explorador.
      expect(draft.effectiveTitle, 'NVDA — Ficha del 04/08/2026');
      expect(draft.normalizedTicker, 'NVDA');
      expect(draft.content, contains(kIntelligenceSnippetHeading));
    });

    test('respeta la carpeta destino si se le pasa una', () {
      final draft = intelligenceNoteDraft(_intelligence(), folderId: 'research');
      expect(draft.folderId, 'research');
    });
  });

  group('appendIntelligenceSnippet', () {
    test('agrega al final y conserva lo que el usuario escribió', () {
      final result = appendIntelligenceSnippet(
        '# Mi tesis\n\nCreo que está caro.\n',
        _intelligence(),
      );

      // El orden importa: lo del usuario primero, la Ficha debajo.
      expect(result.startsWith('# Mi tesis'), isTrue);
      expect(result, contains('Creo que está caro.'));
      expect(result, contains(kIntelligenceSnippetHeading));
      expect(
        result.indexOf('Creo que está caro.'),
        lessThan(result.indexOf(kIntelligenceSnippetHeading)),
      );
    });

    test('sobre un cuerpo vacío no deja líneas en blanco al principio', () {
      final result = appendIntelligenceSnippet('   \n\n', _intelligence());
      expect(result.startsWith('## '), isTrue);
    });

    test('nunca reemplaza el cuerpo existente', () {
      const original = 'Texto irremplazable escrito a mano.';
      expect(
        appendIntelligenceSnippet(original, _intelligence()),
        contains(original),
      );
    });
  });

  // --- Pestaña "Notas" del activo -------------------------------------------------------------

  group('TickerNotesTab', () {
    testWidgets('pide las notas del ticker, no de una carpeta', (tester) async {
      final notes = _FakeNotesRepository();
      await _pumpTab(tester, notes: notes);

      expect(notes.listQueries.single['ticker'], 'NVDA');
      // Es el punto de que los dos ejes sean independientes: una nota de NVDA archivada en cualquier
      // carpeta tiene que aparecer acá.
      expect(notes.listQueries.single['folderId'], isNull);
    });

    testWidgets('lista las notas con su antigüedad y su largo', (tester) async {
      final notes = _FakeNotesRepository(
        page: NotePage(
          items: [
            _summary(id: 'n1', title: 'Tesis NVDA', contentLength: 4200),
            _summary(id: 'n2', title: 'Archivada', folderId: 'research'),
          ],
          total: 2,
          limit: 100,
          offset: 0,
        ),
      );
      await _pumpTab(tester, notes: notes);

      expect(find.text('Notas sobre NVDA · 2'), findsOneWidget);
      expect(find.text('Tesis NVDA'), findsOneWidget);
      // La archivada aparece igual: el filtro es por ticker.
      expect(find.text('Archivada'), findsOneWidget);
      expect(find.textContaining('4,2 mil car.'), findsOneWidget);
    });

    testWidgets('el cuerpo se pide recién al expandir', (tester) async {
      final notes = _FakeNotesRepository(
        page: NotePage(
          items: [_summary(id: 'n1', title: 'Tesis NVDA')],
          total: 1,
          limit: 100,
          offset: 0,
        ),
        note: _note(id: 'n1', content: '## Mi lectura\n\n- Caro pero crece'),
      );
      await _pumpTab(tester, notes: notes);

      // Colapsada no hay markdown renderizado: traer veinte cuerpos por si acaso es exactamente lo
      // que el contrato del listado evita.
      expect(find.byType(MarkdownView), findsNothing);

      await tester.tap(find.text('Tesis NVDA'));
      await tester.pumpAndSettle();

      expect(find.byType(MarkdownView), findsOneWidget);
      expect(find.text('Mi lectura', findRichText: true), findsOneWidget);
      expect(find.text('Caro pero crece', findRichText: true), findsOneWidget);
    });

    testWidgets('sin notas invita a escribir la primera', (tester) async {
      await _pumpTab(tester, notes: _FakeNotesRepository());

      expect(find.textContaining('Todavía no tenés notas sobre NVDA'),
          findsOneWidget);
      expect(find.text('Escribir sobre NVDA'), findsOneWidget);
    });

    testWidgets('el redactor crea la nota ya vinculada al símbolo',
        (tester) async {
      final notes = _FakeNotesRepository();
      await _pumpTab(tester, notes: notes);

      await tester.tap(find.text('Escribir sobre NVDA'));
      await tester.pumpAndSettle();

      expect(find.text('Nueva nota sobre NVDA'), findsOneWidget);
      expect(find.text('Vinculada a NVDA'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Título'),
        'Precio de entrada',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Escribí acá. Soporta Markdown.'),
        'Me interesa abajo de 100.',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
      await tester.pumpAndSettle();

      final draft = notes.createdDrafts.single;
      expect(draft.effectiveTitle, 'Precio de entrada');
      expect(draft.content, 'Me interesa abajo de 100.');
      // El vínculo es lo que la hace reaparecer acá mañana.
      expect(draft.normalizedTicker, 'NVDA');
    });

    testWidgets('un error al guardar se muestra sin cerrar el redactor',
        (tester) async {
      final notes = _FakeNotesRepository()
        ..failure = DioException(
          requestOptions: RequestOptions(path: '/notes'),
          response: Response(
            requestOptions: RequestOptions(path: '/notes'),
            statusCode: 404,
            data: {'detail': 'La carpeta indicada no existe.'},
          ),
        );
      await _pumpTab(tester, notes: notes);

      await tester.tap(find.text('Escribir sobre NVDA'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Título'), 'X');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
      await tester.pumpAndSettle();

      expect(find.text('La carpeta indicada no existe.'), findsOneWidget);
      expect(find.text('Nueva nota sobre NVDA'), findsOneWidget);
    });
  });

  group('inserción de la Ficha', () {
    testWidgets('el botón está deshabilitado si la Ficha no está cargada',
        (tester) async {
      await _pumpTab(tester, notes: _FakeNotesRepository());

      // Dispararlo para PEDIR la Ficha convertiría un gesto de un clic en varios segundos de espera
      // con un resultado que el usuario nunca vio.
      // `byTooltip` matchea el widget del tooltip, que el `IconButton` construye por DEBAJO de sí
      // mismo: para llegar al botón hay que subir, no bajar.
      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip(
            'Abrí la pestaña de Inteligencia Profunda para poder insertarla en una nota',
          ),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('con la Ficha cargada crea una nota con el bloque pegado',
        (tester) async {
      final notes = _FakeNotesRepository();
      await _pumpTab(
        tester,
        notes: notes,
        intelligence: _intelligence(),
      );

      await tester.tap(
        find.byTooltip('Nueva nota con la Ficha de Inteligencia de NVDA'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Nueva nota sobre NVDA'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
      await tester.pumpAndSettle();

      final draft = notes.createdDrafts.single;
      expect(draft.effectiveTitle, 'NVDA — Ficha del 04/08/2026');
      expect(draft.content, contains(kIntelligenceSnippetHeading));
      expect(draft.content, contains('Trimestre récord.'));
      expect(draft.normalizedTicker, 'NVDA');
    });

    testWidgets('agregar la Ficha a una nota existente no borra su cuerpo',
        (tester) async {
      final notes = _FakeNotesRepository(
        page: NotePage(
          items: [_summary(id: 'n1', title: 'Tesis NVDA')],
          total: 1,
          limit: 100,
          offset: 0,
        ),
        note: _note(id: 'n1', content: 'Texto irremplazable escrito a mano.'),
      );
      await _pumpTab(tester, notes: notes, intelligence: _intelligence());

      await tester.tap(find.text('Tesis NVDA'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agregar la Ficha'));
      await tester.pumpAndSettle();

      final (noteId, draft) = notes.savedDrafts.single;
      expect(noteId, 'n1');
      // Lo del usuario sobrevive y queda ARRIBA; la Ficha va debajo.
      expect(draft.content, startsWith('Texto irremplazable escrito a mano.'));
      expect(draft.content, contains(kIntelligenceSnippetHeading));
      expect(find.textContaining('Se agregó la Ficha al final'), findsOneWidget);
    });
  });
}
