import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../data/financial_translation.dart';

/// Qué traducir y con qué contexto.
///
/// Es una clase de valor con `==` y `hashCode` propios porque es la clave del `family`: sin
/// igualdad estructural, dos pedidos idénticos crearían dos providers distintos y cada apertura de
/// la Ficha volvería a pegarle al backend por la misma explicación.
@immutable
class TranslationRequest {
  const TranslationRequest({required this.text, this.context});

  final String text;

  /// De dónde salió el texto (ticker, sección de la Ficha). Cambia mucho la calidad: "múltiplo
  /// alto" se explica distinto si viene de una tecnológica que si viene de un banco. Y entra en la
  /// clave de caché del backend, así que también es parte de la identidad del pedido.
  final String? context;

  @override
  bool operator ==(Object other) =>
      other is TranslationRequest &&
      other.text == text &&
      other.context == context;

  @override
  int get hashCode => Object.hash(text, context);
}

/// Traducción de un texto financiero a lenguaje simple.
///
/// `autoDispose` **con `keepAlive` implícito por uso**: mientras el toggle "Explicar para
/// Principiantes" esté encendido, el provider vive y no se vuelve a pedir; al apagarlo se libera.
/// Reencenderlo cuesta un request pero no una llamada al modelo — el backend cachea por contenido
/// 24 horas, así que la segunda vez vuelve con `servedFromCache`.
final financialTranslationProvider =
    FutureProvider.autoDispose.family<FinancialTranslation, TranslationRequest>(
  (ref, request) => ref
      .watch(financialTranslatorRepositoryProvider)
      .translate(request.text, context: request.context),
);

/// Si el modo "Explicar para Principiantes" está activo.
///
/// Vive fuera de la Ficha (y no como estado local de un widget) para que la preferencia se mantenga
/// al saltar de un activo a otro: alguien que necesita las explicaciones simples las necesita en
/// todos los tickers, no solo en el que tenía abierto cuando prendió el switch.
///
/// No se persiste en disco a propósito: es una ayuda de lectura para un momento puntual, y dejarla
/// encendida entre sesiones haría que cada Ficha arranque disparando traducciones que el usuario
/// quizá ya no necesita.
final beginnerModeProvider = StateProvider<bool>((ref) => false);
