import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/providers.dart';
import '../../watchlist/presentation/watchlist_controller.dart';
import '../data/chat_repository.dart';

/// Pantalla 2: Buscador Conversacional / Chat con el Agente. Wireada a `POST /api/v1/chat`
/// (`ChatRepository.send`) — el selector de ticker es opcional y le pasa al backend contexto
/// de `AlertHistory` reciente para esa pregunta (ver `app/services/chat_service.py`).
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _inputController = TextEditingController();
  final _messages = <ChatMessage>[];
  String? _selectedTicker;
  bool _isSending = false;

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _isSending) return;

    setState(() {
      _messages.add(ChatMessage(text: text, isFromUser: true));
      _inputController.clear();
      _isSending = true;
    });

    try {
      final response = await ref
          .read(chatRepositoryProvider)
          .send(text, ticker: _selectedTicker);
      final suffix = response.groundedInRecentAlert
          ? ''
          : (response.referencedTicker != null
              ? '\n\n(sin un análisis reciente guardado de ${response.referencedTicker})'
              : '');
      setState(
        () => _messages.add(ChatMessage(text: '${response.reply}$suffix', isFromUser: false)),
      );
    } on Object catch (error) {
      setState(
        () => _messages.add(ChatMessage(text: describeApiError(error), isFromUser: false)),
      );
    } finally {
      setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final watchlistAsync = ref.watch(watchlistProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Preguntale al agente'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: watchlistAsync.when(
              data: (items) => Row(
                children: [
                  const Text('Sobre: '),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButton<String?>(
                      isExpanded: true,
                      value: _selectedTicker,
                      hint: const Text('Ningún ticker (pregunta general)'),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('Ningún ticker'),
                        ),
                        for (final item in items)
                          DropdownMenuItem<String?>(
                            value: item.ticker,
                            child: Text(item.ticker),
                          ),
                      ],
                      onChanged: (value) => setState(() => _selectedTicker = value),
                    ),
                  ),
                ],
              ),
              loading: () => const SizedBox.shrink(),
              error: (error, stackTrace) => const SizedBox.shrink(),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Preguntá lo que quieras sobre un activo, ej: '
                        '"¿qué pasó con NVDA hoy?"',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) => _ChatBubble(message: _messages[index]),
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
                      decoration: const InputDecoration(
                        hintText: 'Escribí tu pregunta…',
                        border: OutlineInputBorder(),
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
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton.filled(onPressed: _send, icon: const Icon(Icons.send)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final alignment = message.isFromUser ? Alignment.centerRight : Alignment.centerLeft;
    final color = message.isFromUser
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;

    return Align(
      alignment: alignment,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(16)),
        child: Text(message.text),
      ),
    );
  }
}
