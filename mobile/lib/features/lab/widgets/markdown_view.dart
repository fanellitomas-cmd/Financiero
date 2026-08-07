import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Visor de Markdown del Investment Lab.
///
/// Escrito a mano y sin dependencia externa a propósito: el subconjunto que una nota de
/// investigación necesita es chico y cerrado, y traer un renderer completo agregaría un paquete
/// entero (con su propio parser de HTML embebido y sus reglas de tipografía) para usarle un 10%.
/// Además deja el estilo enteramente bajo el tema de la app, que es lo que hace que una nota se vea
/// parte del producto y no un README pegado adentro.
///
/// **Subconjunto soportado**, y es deliberadamente todo lo que se soporta:
///
///   - Títulos `#`, `##`, `###`
///   - Viñetas `-`, `*`, `+` y listas numeradas `1.`
///   - Citas `>`
///   - Bloques de código con ``` y código inline con acentos graves
///   - Separadores `---`
///   - Negrita `**así**`, itálica `*así*` o `_así_`
///
/// Lo que no está en esa lista (tablas, links, imágenes, HTML) se muestra como texto literal en vez
/// de desaparecer: una nota es texto del usuario y perder un carácter que escribió sería peor que
/// mostrarlo sin formato.
class MarkdownView extends StatelessWidget {
  const MarkdownView({super.key, required this.source, this.textScale = 1});

  final String source;

  /// Escala del cuerpo. La pestaña de notas del activo usa un tamaño menor que el editor, donde el
  /// texto es el contenido principal de la pantalla.
  final double textScale;

  @override
  Widget build(BuildContext context) {
    final blocks = parseMarkdownBlocks(source);
    if (blocks.isEmpty) {
      return Text(
        'Esta nota todavía no tiene contenido.',
        style: TextStyle(
          color: AppTheme.textMuted,
          fontSize: 13 * textScale,
          fontStyle: FontStyle.italic,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final block in blocks) _MarkdownBlockView(block: block, textScale: textScale),
      ],
    );
  }
}

enum MarkdownBlockKind {
  heading1,
  heading2,
  heading3,
  paragraph,
  bullet,
  ordered,
  quote,
  code,
  rule,
}

@immutable
class MarkdownBlock {
  const MarkdownBlock(this.kind, this.text, {this.ordinal});

  final MarkdownBlockKind kind;

  /// El contenido sin el marcador (`## Título` llega como `Título`).
  final String text;

  /// Número mostrado en una lista numerada. Se conserva el que escribió el usuario en vez de
  /// renumerar: si alguien escribió "1. 1. 1." es porque quiso, y renumerar cambiaría su texto.
  final int? ordinal;

  @override
  bool operator ==(Object other) =>
      other is MarkdownBlock &&
      other.kind == kind &&
      other.text == text &&
      other.ordinal == ordinal;

  @override
  int get hashCode => Object.hash(kind, text, ordinal);

  @override
  String toString() => 'MarkdownBlock($kind, "$text", ordinal: $ordinal)';
}

final _headingPattern = RegExp(r'^(#{1,3})\s+(.*)$');
final _bulletPattern = RegExp(r'^\s{0,3}[-*+]\s+(.*)$');
final _orderedPattern = RegExp(r'^\s{0,3}(\d{1,3})[.)]\s+(.*)$');
final _rulePattern = RegExp(r'^\s{0,3}([-*_])\s*(\1\s*){2,}$');
final _fencePattern = RegExp(r'^\s{0,3}```');

/// Parte el texto en bloques. Pura y sin widgets, para poder testear el parser sin montar la UI.
List<MarkdownBlock> parseMarkdownBlocks(String source) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final blocks = <MarkdownBlock>[];

  // Párrafos y citas se acumulan entre líneas: en Markdown un salto simple es continuación del
  // mismo párrafo, no un párrafo nuevo. Sin esto, un texto escrito con márgenes angostos se
  // renderizaría como una lista de renglones sueltos.
  final buffer = <String>[];
  var bufferKind = MarkdownBlockKind.paragraph;

  void flush() {
    if (buffer.isEmpty) return;
    blocks.add(MarkdownBlock(bufferKind, buffer.join(' ').trim()));
    buffer.clear();
    bufferKind = MarkdownBlockKind.paragraph;
  }

  var index = 0;
  while (index < lines.length) {
    final line = lines[index];
    final trimmed = line.trim();

    if (_fencePattern.hasMatch(line)) {
      flush();
      final code = <String>[];
      index++;
      while (index < lines.length && !_fencePattern.hasMatch(lines[index])) {
        code.add(lines[index]);
        index++;
      }
      // Se salta la cerradura si está; si el usuario nunca la cerró, el bloque llega hasta el final
      // igual — abortar dejaría el resto de la nota invisible.
      if (index < lines.length) index++;
      blocks.add(MarkdownBlock(MarkdownBlockKind.code, code.join('\n')));
      continue;
    }

    if (trimmed.isEmpty) {
      flush();
      index++;
      continue;
    }

    if (_rulePattern.hasMatch(trimmed)) {
      flush();
      blocks.add(const MarkdownBlock(MarkdownBlockKind.rule, ''));
      index++;
      continue;
    }

    final heading = _headingPattern.firstMatch(trimmed);
    if (heading != null) {
      flush();
      final level = heading.group(1)!.length;
      blocks.add(
        MarkdownBlock(
          switch (level) {
            1 => MarkdownBlockKind.heading1,
            2 => MarkdownBlockKind.heading2,
            _ => MarkdownBlockKind.heading3,
          },
          heading.group(2)!.trim(),
        ),
      );
      index++;
      continue;
    }

    final bullet = _bulletPattern.firstMatch(line);
    if (bullet != null) {
      flush();
      blocks.add(MarkdownBlock(MarkdownBlockKind.bullet, bullet.group(1)!.trim()));
      index++;
      continue;
    }

    final ordered = _orderedPattern.firstMatch(line);
    if (ordered != null) {
      flush();
      blocks.add(
        MarkdownBlock(
          MarkdownBlockKind.ordered,
          ordered.group(2)!.trim(),
          ordinal: int.tryParse(ordered.group(1)!),
        ),
      );
      index++;
      continue;
    }

    if (trimmed.startsWith('>')) {
      if (bufferKind != MarkdownBlockKind.quote) flush();
      bufferKind = MarkdownBlockKind.quote;
      buffer.add(trimmed.substring(1).trim());
      index++;
      continue;
    }

    if (bufferKind != MarkdownBlockKind.paragraph) flush();
    buffer.add(trimmed);
    index++;
  }

  flush();
  return blocks;
}

/// Un tramo de texto inline con sus marcas ya resueltas.
@immutable
class MarkdownSpan {
  const MarkdownSpan(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.code = false,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool code;

  @override
  bool operator ==(Object other) =>
      other is MarkdownSpan &&
      other.text == text &&
      other.bold == bold &&
      other.italic == italic &&
      other.code == code;

  @override
  int get hashCode => Object.hash(text, bold, italic, code);

  @override
  String toString() =>
      'MarkdownSpan("$text"${bold ? ", bold" : ""}${italic ? ", italic" : ""}'
      '${code ? ", code" : ""})';
}

/// Resuelve la negrita, la itálica y el código inline de una línea.
///
/// Un marcador sin cierre se deja como texto literal: quien escribe "el 3 * 4" no está abriendo una
/// itálica, y comerse el asterisco cambiaría lo que escribió.
List<MarkdownSpan> parseInlineMarkdown(String text) {
  final spans = <MarkdownSpan>[];
  _appendInline(spans, text, bold: false, italic: false);
  // Se fusionan los tramos contiguos con las mismas marcas para que el resultado sea comparable en
  // los tests y no dependa de por dónde cortó la recursión.
  final merged = <MarkdownSpan>[];
  for (final span in spans) {
    if (span.text.isEmpty) continue;
    final last = merged.isEmpty ? null : merged.last;
    if (last != null &&
        last.bold == span.bold &&
        last.italic == span.italic &&
        last.code == span.code) {
      merged[merged.length - 1] = MarkdownSpan(
        '${last.text}${span.text}',
        bold: last.bold,
        italic: last.italic,
        code: last.code,
      );
    } else {
      merged.add(span);
    }
  }
  return merged;
}

void _appendInline(
  List<MarkdownSpan> out,
  String text, {
  required bool bold,
  required bool italic,
}) {
  var cursor = 0;
  while (cursor < text.length) {
    final marker = _nextMarker(text, cursor);
    if (marker == null) {
      out.add(MarkdownSpan(text.substring(cursor), bold: bold, italic: italic));
      return;
    }

    if (marker.start > cursor) {
      out.add(
        MarkdownSpan(text.substring(cursor, marker.start),
            bold: bold, italic: italic),
      );
    }

    final inner = text.substring(marker.contentStart, marker.contentEnd);
    if (marker.isCode) {
      // El código inline no se re-parsea: un asterisco dentro de `a*b` es un asterisco.
      out.add(MarkdownSpan(inner, bold: bold, italic: italic, code: true));
    } else {
      _appendInline(
        out,
        inner,
        bold: bold || marker.isBold,
        italic: italic || !marker.isBold,
      );
    }
    cursor = marker.end;
  }
}

@immutable
class _Marker {
  const _Marker({
    required this.start,
    required this.contentStart,
    required this.contentEnd,
    required this.end,
    required this.isBold,
    required this.isCode,
  });

  final int start;
  final int contentStart;
  final int contentEnd;
  final int end;
  final bool isBold;
  final bool isCode;
}

_Marker? _nextMarker(String text, int from) {
  for (var index = from; index < text.length; index++) {
    final char = text[index];

    if (char == '`') {
      final close = text.indexOf('`', index + 1);
      if (close > index + 1) {
        return _Marker(
          start: index,
          contentStart: index + 1,
          contentEnd: close,
          end: close + 1,
          isBold: false,
          isCode: true,
        );
      }
      continue;
    }

    if (char == '*' || char == '_') {
      // `**` primero: si se probara el marcador simple antes, "**texto**" abriría una itálica con
      // un asterisco suelto adentro.
      final isDouble = index + 1 < text.length && text[index + 1] == char;
      final token = isDouble ? '$char$char' : char;
      final searchFrom = index + token.length;
      if (searchFrom >= text.length) continue;

      // El marcador de apertura no puede ir seguido de un espacio. Es la regla que hace que "3 * 4
      // = 12" siga siendo una multiplicación y no el comienzo de una itálica que se coma media
      // línea. Vale igual para el cierre: "* 4 *" tampoco abre nada.
      if (_isSpace(text[searchFrom])) continue;

      // `_` no marca nada dentro de una palabra: `free_cash_flow` es un nombre de métrica, no una
      // itálica. El asterisco sí puede, porque nadie escribe identificadores con asteriscos.
      if (char == '_' && index > 0 && _isWordChar(text[index - 1])) continue;

      final close = text.indexOf(token, searchFrom);
      if (close <= searchFrom) continue;
      if (_isSpace(text[close - 1])) continue;
      final after = close + token.length;
      if (char == '_' && after < text.length && _isWordChar(text[after])) {
        continue;
      }

      return _Marker(
        start: index,
        contentStart: searchFrom,
        contentEnd: close,
        end: after,
        isBold: isDouble,
        isCode: false,
      );
    }
  }
  return null;
}

bool _isSpace(String char) => char.trim().isEmpty;

final _wordCharPattern = RegExp(r'[\w]');

bool _isWordChar(String char) => _wordCharPattern.hasMatch(char);

class _MarkdownBlockView extends StatelessWidget {
  const _MarkdownBlockView({required this.block, required this.textScale});

  final MarkdownBlock block;
  final double textScale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = TextStyle(fontSize: 14 * textScale, height: 1.55);

    return switch (block.kind) {
      MarkdownBlockKind.rule => const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Divider(height: 1, color: AppTheme.border),
        ),
      MarkdownBlockKind.heading1 => _blockPadding(
          top: 6,
          child: _text(
            block.text,
            theme.textTheme.titleLarge?.copyWith(fontSize: 20 * textScale) ??
                body,
          ),
        ),
      MarkdownBlockKind.heading2 => _blockPadding(
          top: 6,
          child: _text(
            block.text,
            theme.textTheme.titleMedium?.copyWith(fontSize: 16 * textScale) ??
                body,
          ),
        ),
      MarkdownBlockKind.heading3 => _blockPadding(
          top: 4,
          child: _text(
            block.text,
            (theme.textTheme.titleSmall ?? body).copyWith(
              fontSize: 14 * textScale,
              color: AppTheme.accent,
            ),
          ),
        ),
      MarkdownBlockKind.paragraph => _blockPadding(child: _text(block.text, body)),
      MarkdownBlockKind.bullet => _blockPadding(
          bottom: 4,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(top: 7 * textScale, right: 8),
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: const BoxDecoration(
                    color: AppTheme.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Expanded(child: _text(block.text, body)),
            ],
          ),
        ),
      MarkdownBlockKind.ordered => _blockPadding(
          bottom: 4,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 22 * textScale,
                child: Text(
                  '${block.ordinal ?? 1}.',
                  // Monoespaciada para que los números de una lista larga queden alineados y el
                  // texto arranque en la misma columna en todos los ítems.
                  style: AppTheme.numeric(
                    fontSize: 13 * textScale,
                    color: AppTheme.accent,
                  ),
                ),
              ),
              Expanded(child: _text(block.text, body)),
            ],
          ),
        ),
      MarkdownBlockKind.quote => _blockPadding(
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: const BoxDecoration(
              color: AppTheme.surfaceSunken,
              border: Border(
                left: BorderSide(color: AppTheme.accent, width: 3),
              ),
            ),
            child: _text(
              block.text,
              body.copyWith(
                color: AppTheme.textMuted,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ),
      MarkdownBlockKind.code => _blockPadding(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.surfaceSunken,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppTheme.border),
            ),
            // El bloque de código NO se parsea inline y scrollea horizontal en vez de cortar:
            // partir una línea de código cambia lo que dice.
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                block.text,
                style: AppTheme.numeric(fontSize: 12.5 * textScale),
              ),
            ),
          ),
        ),
    };
  }

  Widget _blockPadding({required Widget child, double top = 0, double bottom = 8}) =>
      Padding(padding: EdgeInsets.only(top: top, bottom: bottom), child: child);

  /// `Text.rich` y NUNCA `RichText`: `RichText` no hereda el `DefaultTextStyle` del tema, así que
  /// cae en la familia por defecto de Flutter ("Roboto"), que en Web no está bundleada — el texto
  /// terminaría invisible sin ningún error a la vista.
  Widget _text(String source, TextStyle style) {
    final spans = parseInlineMarkdown(source);
    return Text.rich(
      TextSpan(
        children: [
          for (final span in spans)
            TextSpan(
              text: span.text,
              style: span.code
                  ? AppTheme.numeric(
                      fontSize: (style.fontSize ?? 14) * 0.92,
                      color: AppTheme.accent,
                    )
                  : style.copyWith(
                      fontWeight: span.bold ? FontWeight.bold : style.fontWeight,
                      fontStyle: span.italic ? FontStyle.italic : style.fontStyle,
                    ),
            ),
        ],
      ),
      style: style,
    );
  }
}
