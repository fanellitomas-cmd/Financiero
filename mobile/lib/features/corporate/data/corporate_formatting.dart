import 'package:intl/intl.dart';

import 'corporate_models.dart';

/// Formateo compartido por la UI del Hub y por los bloques Markdown que se guardan en el Lab.
///
/// Está en un solo lugar porque los dos tienen que decir **exactamente lo mismo**: una nota que
/// dice "+4,9%" y una pantalla que dice "+4,86%" sobre el mismo balance son dos afirmaciones
/// distintas sobre un mismo hecho, y la nota es la que queda.
///
/// La regla que atraviesa el archivo: **un dato ausente se escribe `—`, nunca `0`.** Un EPS que el
/// proveedor no trajo y un EPS de cero centavos son cosas opuestas.

/// Marca de dato ausente. Un guion largo y no "N/D" ni "0": ocupa poco, no compite con los números
/// de al lado y no se puede confundir con un valor.
const String kMissingValue = '—';

/// EPS y otros valores por acción: dos decimales siempre.
///
/// A diferencia de los porcentajes, acá los ceros finales SÍ se conservan: "1,20" y "1,2" son el
/// mismo número pero en una columna de EPS el primero se alinea y el segundo no, y estas cifras se
/// leen comparando filas.
String formatEps(double? value) {
  if (value == null) return kMissingValue;
  return _decimalComma(value.toStringAsFixed(2));
}

/// Ídem con signo explícito, para las diferencias: "+0,07" dice más que "0,07".
String formatEpsDelta(double? value) {
  if (value == null) return kMissingValue;
  final formatted = _decimalComma(value.abs().toStringAsFixed(2));
  if (value > 0) return '+$formatted';
  if (value < 0) return '−$formatted';
  return formatted;
}

/// Montos de ingresos, abreviados. Se usa la escala corta en inglés que ya usa la app en la
/// búsqueda NL (M / MM / B) para no tener dos vocabularios de magnitud en el mismo producto.
String formatRevenue(double? value) {
  if (value == null) return kMissingValue;
  final abs = value.abs();
  final sign = value < 0 ? '−' : '';
  if (abs >= 1e12) return '${sign}US\$ ${_decimalComma((abs / 1e12).toStringAsFixed(2))} B';
  if (abs >= 1e9) return '${sign}US\$ ${_decimalComma((abs / 1e9).toStringAsFixed(2))} MM';
  if (abs >= 1e6) return '${sign}US\$ ${_decimalComma((abs / 1e6).toStringAsFixed(0))} M';
  return '${sign}US\$ ${_decimalComma(abs.toStringAsFixed(0))}';
}

/// Porcentaje de sorpresa, con signo. Un decimal: la precisión de un cociente sobre estimaciones de
/// analistas no llega al segundo, y mostrar "4,86%" sugiere una exactitud que el dato no tiene.
///
/// **`null` devuelve [kMissingValue] a propósito y eso no es un caso raro:** el backend omite el
/// porcentaje cuando la base estimada es demasiado chica para que el cociente signifique algo.
String formatSurprisePct(double? value) {
  if (value == null) return kMissingValue;
  final formatted = _decimalComma(value.abs().toStringAsFixed(1));
  if (value > 0) return '+$formatted%';
  if (value < 0) return '−$formatted%';
  return '$formatted%';
}

/// Tasa 0..1 como porcentaje entero ("75%"). `null` -> [kMissingValue].
String formatRate(double? rate) {
  if (rate == null) return kMissingValue;
  return '${(rate * 100).round()}%';
}

/// Fecha de un balance o de una presentación: "27/08/2026".
String formatCorporateDate(DateTime? date) {
  if (date == null) return kMissingValue;
  return DateFormat('dd/MM/yyyy').format(date.toLocal());
}

/// Día con su nombre, para los encabezados de grupo del calendario: "jue 27/08".
///
/// El día de la semana se escribe en castellano acá y no con `DateFormat('EEE', 'es')` porque eso
/// requiere inicializar los datos de locale de `intl`, que la app no carga — sin eso, `intl` cae a
/// inglés en silencio y el calendario mostraría "Thu".
String formatCalendarDay(DateTime date) {
  const names = ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'];
  final local = date.toLocal();
  // `DateTime.weekday` es 1..7 empezando en lunes.
  return '${names[local.weekday - 1]} ${DateFormat('dd/MM').format(local)}';
}

/// Antigüedad de una noticia en palabras ("hace 2 h"), o la fecha si ya pasó una semana.
///
/// Duplica a propósito la forma de `note_formatting.dart` en vez de importarla: esa vive en el Lab y
/// mide "cuándo toqué esto por última vez"; esta mide "qué tan vieja es la información", que es la
/// razón por la que una noticia sirve o no. Compartirla ataría dos significados que pueden necesitar
/// evolucionar distinto.
String formatNewsAge(DateTime? published, {DateTime? now}) {
  if (published == null) return 'sin fecha';
  final delta = (now ?? DateTime.now()).toUtc().difference(published.toUtc());
  if (delta.isNegative || delta.inMinutes < 1) return 'recién';
  if (delta.inMinutes < 60) return 'hace ${delta.inMinutes} min';
  if (delta.inHours < 24) return 'hace ${delta.inHours} h';
  if (delta.inDays < 7) return 'hace ${delta.inDays} d';
  return DateFormat('dd/MM/yyyy').format(published.toLocal());
}

/// Cuántos días faltan para un balance, en palabras. Es lo que decide si una fila del calendario se
/// lee como "esto es hoy" o como "esto es en tres semanas".
String formatDaysUntil(DateTime eventDate, {DateTime? now}) {
  final today = _dayOnly(now ?? DateTime.now());
  final target = _dayOnly(eventDate);
  final days = target.difference(today).inDays;
  return switch (days) {
    0 => 'hoy',
    1 => 'mañana',
    -1 => 'ayer',
    < 0 => 'hace ${-days} d',
    _ => 'en $days d',
  };
}

/// El período fiscal en una etiqueta, con lo que haya: la etiqueta del proveedor si la mandó, el
/// cierre del trimestre si no.
///
/// No se convierte una fecha de cierre en "Q2": el trimestre que cierra en junio es el Q2 de
/// algunas empresas y el Q3 de otras, y adivinarlo le inventaría el calendario fiscal a la empresa.
String? formatFiscalPeriod(EarningsEvent event) {
  final label = event.fiscalPeriod?.trim();
  if (label != null && label.isNotEmpty) return label;
  final end = event.fiscalPeriodEnd;
  if (end == null) return null;
  return 'cierre ${formatCorporateDate(end)}';
}

DateTime _dayOnly(DateTime value) {
  final local = value.toLocal();
  return DateTime(local.year, local.month, local.day);
}

/// Coma decimal, que es la convención del castellano rioplatense en el que está escrita la app.
String _decimalComma(String value) => value.replaceAll('.', ',');
