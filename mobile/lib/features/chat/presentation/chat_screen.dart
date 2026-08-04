import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../watchlist/data/watchlist_models.dart';
import '../../watchlist/presentation/watchlist_controller.dart';
import '../data/chat_repository.dart';
import 'chat_ticker_controller.dart';

/// Pantalla 2: Buscador Conversacional / Chat con el Agente, wireado a `POST /api/v1/chat`.
///
/// El activo vinculado (`chatTickerProvider`) define qué contexto arma el backend
/// (`app/services/chat_service.py`):
///   - **Con ticker:** cotización en vivo, bolsa del catálogo y el último análisis persistido de
///     ese activo.
///   - **Sin ticker:** estado general del mercado (alzas y bajas de la jornada).
///
/// El ticker se hereda de la selección global (tocar un activo en la Watchlist o en el heatmap) y
/// se puede desvincular desde el chip de la cabecera para volver a preguntas generales.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _inputController = TextEditingController();
  final _messages = <ChatMessage>[];
  bool _isSending = false;

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _isSending) return;

    // El ticker se lee al momento de enviar, no al de tipear: si el usuario cambia de activo con
    // el mensaje a medio escribir, la pregunta sale sobre el activo que tiene a la vista.
    final ticker = ref.read(chatTickerProvider);

    setState(() {
      _messages.add(ChatMessage(text: text, isFromUser: true));
      _inputController.clear();
      _isSending = true;
    });

    try {
      final response =
          await ref.read(chatRepositoryProvider).send(text, ticker: ticker);
      // Se aclara cuándo la respuesta NO se apoyó en un análisis guardado: el backend igual manda
      // cotización en vivo, así que la respuesta es válida, pero el usuario merece saber que no
      // hay una ficha profunda reciente detrás.
      final suffix = response.groundedInRecentAlert
          ? ''
          : (response.referencedTicker != null
              ? '\n\n(sin un análisis reciente guardado de '
                  '${response.referencedTicker})'
              : '');
      setState(
        () => _messages.add(
          ChatMessage(text: '${response.reply}$suffix', isFromUser: false),
        ),
      );
    } on Object catch (error) {
      setState(
        () => _messages.add(
          ChatMessage(text: describeApiError(error), isFromUser: false),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeTicker = ref.watch(chatTickerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Preguntale al agente'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ChatContextChip(activeTicker: activeTicker),
            ),
          ),
        ),
      ),
      // Ancho acotado en escritorio: un chat estirado a 1900px deja las burbujas perdidas a
      // los costados y el ojo tiene que barrer toda la pantalla para seguir la conversación.
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            children: [
              Expanded(
                child: _messages.isEmpty
                    ? _EmptyChatState(activeTicker: activeTicker)
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) =>
                            _ChatBubble(message: _messages[index]),
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _inputController,
                          onSubmitted: (_) => _send(),
                          decoration: InputDecoration(
                            hintText: activeTicker == null
                                ? 'Preguntá sobre el mercado…'
                                : 'Preguntá sobre $activeTicker…',
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _isSending
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : IconButton.filled(
                              onPressed: _send,
                              icon: const Icon(Icons.send),
                            ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Chip de contexto de la cabecera: dice sobre qué activo se está conversando y permite cambiarlo
/// o desvincularlo.
///
/// Con ticker va tintado con el acento (cian) — es un estado activo de la UI, no una señal de
/// mercado, así que no corresponde verde ni rojo. Sin ticker queda en superficie hundida:
/// legible, pero sin reclamar atención.
///
/// Público (no `_ChatContextChip`) para poder testearlo aislado sin levantar toda la pantalla.
class ChatContextChip extends ConsumerWidget {
  const ChatContextChip({super.key, required this.activeTicker});

  final String? activeTicker;

  Future<void> _pickTicker(BuildContext context, WidgetRef ref) async {
    final items = ref.read(watchlistProvider).valueOrNull ?? const [];
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Agregá activos a tu watchlist para conversar sobre uno en particular.',
          ),
        ),
      );
      return;
    }

    final picked = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('¿Sobre qué activo querés conversar?'),
        children: [
          for (final item in items)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(item.ticker),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Text(item.ticker, style: AppTheme.tickerSymbol),
                    const SizedBox(width: 12),
                    Text(
                      item.assetType == AssetType.stock ? 'Acción' : 'Cripto',
                      style: const TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );

    if (picked != null) {
      ref.read(chatTickerProvider.notifier).select(picked);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ticker = activeTicker;
    final isLinked = ticker != null;
    final color = isLinked ? AppTheme.accent : AppTheme.textMuted;

    return Container(
      decoration: isLinked
          ? AppTheme.badgeDecoration(color)
          : BoxDecoration(
              color: AppTheme.surfaceSunken,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppTheme.border),
            ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Tocar el chip cambia de activo; la X lo desvincula. Dos acciones distintas en el
          // mismo chip, cada una con su propia área táctil.
          InkWell(
            onTap: () => _pickTicker(context, ref),
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: EdgeInsets.only(
                left: 12,
                right: isLinked ? 6 : 12,
                top: 7,
                bottom: 7,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isLinked ? Icons.insights : Icons.public,
                    size: 15,
                    color: color,
                  ),
                  const SizedBox(width: 7),
                  if (isLinked) ...[
                    const Text(
                      'Conversando sobre:',
                      style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      ticker,
                      style: AppTheme.tickerSymbol.copyWith(
                        fontSize: 12,
                        color: color,
                      ),
                    ),
                  ] else
                    const Text(
                      'Pregunta general de mercado',
                      style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                    ),
                ],
              ),
            ),
          ),
          if (isLinked)
            InkWell(
              onTap: () => ref.read(chatTickerProvider.notifier).unlink(),
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.only(
                  left: 2,
                  right: 10,
                  top: 7,
                  bottom: 7,
                ),
                child: Tooltip(
                  message: 'Desvincular y preguntar sobre el mercado',
                  child: Icon(Icons.close, size: 15, color: color),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyChatState extends StatelessWidget {
  const _EmptyChatState({required this.activeTicker});

  final String? activeTicker;

  @override
  Widget build(BuildContext context) {
    // El ejemplo cambia según el contexto: sugerirle "¿qué pasó con NVDA?" a alguien que tiene
    // AAPL vinculado invita a una pregunta que va a salir sobre el activo equivocado.
    final hint = activeTicker == null
        ? 'Preguntá por el estado del mercado, ej: "¿cómo viene la jornada?"\n\n'
            'Para conversar sobre un activo puntual, elegilo en el chip de arriba.'
        : 'Preguntá lo que quieras sobre $activeTicker, ej: "¿qué le pasó hoy?"';

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          hint,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppTheme.textMuted),
        ),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final alignment =
        message.isFromUser ? Alignment.centerRight : Alignment.centerLeft;
    // Burbuja del usuario tintada con el acento; la del agente en superficie con borde, para
    // que se distinga de un vistazo quién habla sin depender de la alineación sola.
    return Align(
      alignment: alignment,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        // 78% del ancho disponible (no 280px fijos): en el chat de escritorio, acotado a
        // 760px, una burbuja de 280 dejaba media línea de texto por renglón.
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        decoration: BoxDecoration(
          color: message.isFromUser
              ? AppTheme.accent.withValues(alpha: 0.16)
              : AppTheme.surface,
          borderRadius: BorderRadius.circular(AppTheme.radius + 4),
          border: Border.all(
            color: message.isFromUser
                ? AppTheme.accent.withValues(alpha: 0.4)
                : AppTheme.border,
          ),
        ),
        child: Text(message.text),
      ),
    );
  }
}
