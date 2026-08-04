import 'package:financiero_app/core/layout/breakpoints.dart';
import 'package:financiero_app/core/widgets/master_detail_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Envuelve un widget forzando un tamaño de ventana concreto, que es lo que decide el layout
/// adaptativo. Se usa `MediaQuery` explícito en vez de tocar `tester.view` porque así cada test
/// declara su ancho al lado de lo que espera, sin estado global que haya que restaurar después.
Widget _atWidth(double width, Widget child) {
  return MediaQuery(
    data: MediaQueryData(size: Size(width, 900)),
    child: MaterialApp(home: child),
  );
}

void main() {
  group('Breakpoints', () {
    /// Los umbrales se testean en el borde exacto (justo abajo, justo en el valor) porque un
    /// `>` donde va un `>=` es invisible mirando la app: solo se manifiesta en el ancho puntual.
    testWidgets('isDesktop cambia exactamente en 768px', (tester) async {
      final results = <double, bool>{};
      for (final width in [767.0, 768.0, 1200.0]) {
        await tester.pumpWidget(
          _atWidth(
            width,
            Builder(
              builder: (context) {
                results[width] = context.isDesktop;
                return const SizedBox.shrink();
              },
            ),
          ),
        );
      }

      expect(results[767.0], isFalse);
      expect(results[768.0], isTrue);
      expect(results[1200.0], isTrue);
    });

    testWidgets('isMasterDetail cambia exactamente en 1100px', (tester) async {
      final results = <double, bool>{};
      for (final width in [1099.0, 1100.0, 1600.0]) {
        await tester.pumpWidget(
          _atWidth(
            width,
            Builder(
              builder: (context) {
                results[width] = context.isMasterDetail;
                return const SizedBox.shrink();
              },
            ),
          ),
        );
      }

      expect(results[1099.0], isFalse);
      expect(results[1100.0], isTrue);
      expect(results[1600.0], isTrue);
    });

    testWidgets('hay una franja donde es escritorio pero no master-detail',
        (tester) async {
      // Los dos umbrales son distintos a propósito: en una tablet apaisada entra la nav
      // lateral pero no dos columnas legibles. Si alguien los unifica, este test lo frena.
      late bool isDesktop;
      late bool isMasterDetail;
      await tester.pumpWidget(
        _atWidth(
          900,
          Builder(
            builder: (context) {
              isDesktop = context.isDesktop;
              isMasterDetail = context.isMasterDetail;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(isDesktop, isTrue);
      expect(isMasterDetail, isFalse);
    });
  });

  group('MasterDetailLayout', () {
    const master = Text('panel-maestro');
    const detail = Text('panel-detalle');

    testWidgets('en ancho de teléfono muestra solo el maestro', (tester) async {
      await tester.pumpWidget(
        _atWidth(420, const MasterDetailLayout(master: master, detail: detail)),
      );

      expect(find.text('panel-maestro'), findsOneWidget);
      // Clave: el detalle no se construye siquiera. Si se construyera oculto, la ficha
      // dispararía su fetch on-demand en mobile sin que nadie la esté mirando.
      expect(find.text('panel-detalle'), findsNothing);
    });

    testWidgets('en ancho de escritorio muestra los dos paneles',
        (tester) async {
      await tester.pumpWidget(
        _atWidth(
            1400, const MasterDetailLayout(master: master, detail: detail)),
      );

      expect(find.text('panel-maestro'), findsOneWidget);
      expect(find.text('panel-detalle'), findsOneWidget);
    });

    testWidgets('el panel maestro respeta su ancho fijo', (tester) async {
      await tester.pumpWidget(
        _atWidth(
          1400,
          const MasterDetailLayout(
            master: master,
            detail: detail,
            masterWidth: 320,
          ),
        ),
      );

      final masterBox = tester.getSize(
        find
            .ancestor(
              of: find.text('panel-maestro'),
              matching: find.byType(SizedBox),
            )
            .first,
      );
      expect(masterBox.width, 320);
    });

    testWidgets('el placeholder explica que falta elegir un activo',
        (tester) async {
      await tester.pumpWidget(
        _atWidth(
          1400,
          const MasterDetailLayout(
            master: master,
            detail: DetailPanelPlaceholder(message: 'Elegí un activo'),
          ),
        ),
      );

      expect(find.text('Elegí un activo'), findsOneWidget);
    });
  });
}
