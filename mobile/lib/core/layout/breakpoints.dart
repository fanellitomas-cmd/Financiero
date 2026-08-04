import 'package:flutter/widgets.dart';

/// Umbrales de layout de la app. Un único lugar para que "¿es pantalla ancha?" signifique lo
/// mismo en todas las pantallas — si cada widget eligiera su propio número, la nav lateral y el
/// panel de detalle podrían aparecer en anchos distintos y el layout quedaría incoherente.
class Breakpoints {
  const Breakpoints._();

  /// Desde acá se considera "escritorio": la nav pasa de barra inferior a `NavigationRail`.
  /// 768 es el ancho de una tablet en vertical — abajo de eso, una nav lateral se come
  /// demasiado del espacio útil.
  static const double desktop = 768;

  /// Desde acá hay lugar para lista + detalle lado a lado. Es más alto que `desktop` a
  /// propósito: entre 768 y 1100 hay espacio para la nav lateral pero no para partir el
  /// contenido en dos columnas legibles (la ficha de un activo con su chart necesita ~600px
  /// para no verse apretada).
  static const double masterDetail = 1100;
}

extension BreakpointContext on BuildContext {
  double get _width => MediaQuery.sizeOf(this).width;

  bool get isDesktop => _width >= Breakpoints.desktop;

  bool get isMasterDetail => _width >= Breakpoints.masterDetail;
}
