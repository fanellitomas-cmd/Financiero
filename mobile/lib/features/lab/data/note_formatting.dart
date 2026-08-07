import 'package:intl/intl.dart';

/// Formateo compartido entre el explorador y el editor de notas.

/// "hace 3 min", "hace 2 h", "hace 4 d", o la fecha si ya pasó una semana.
///
/// Relativo y no una fecha absoluta porque en una lista de notas lo que importa es cuál toqué
/// último, no el día exacto: "hace 5 min" ordena mentalmente la lista, "06/08/2026" obliga a
/// calcular. A partir de una semana se invierte (la fecha ya dice más que "hace 23 d") y por eso
/// ahí sí se muestra absoluta.
///
/// `now` es inyectable para que los tests no dependan del reloj.
String formatRelativeTime(DateTime timestamp, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  // Se comparan en UTC: los timestamps del backend llegan con zona y `DateTime.now()` es local, así
  // que restarlos sin normalizar daría el offset de la zona como si fuera antigüedad.
  final delta = reference.toUtc().difference(timestamp.toUtc());

  if (delta.isNegative || delta.inMinutes < 1) return 'recién';
  if (delta.inMinutes < 60) return 'hace ${delta.inMinutes} min';
  if (delta.inHours < 24) return 'hace ${delta.inHours} h';
  if (delta.inDays < 7) return 'hace ${delta.inDays} d';
  return DateFormat('dd/MM/yyyy').format(timestamp.toLocal());
}

/// Largo del cuerpo en una unidad legible: caracteres hasta mil, después "1,2 mil".
///
/// Existe para que el explorador pueda distinguir una nota de dos líneas de una tesis de veinte
/// páginas sin traerse ninguna de las dos.
String formatContentLength(int characters) {
  if (characters == 0) return 'vacía';
  if (characters < 1000) return '$characters car.';
  return '${(characters / 1000).toStringAsFixed(1).replaceAll('.', ',')} mil car.';
}
