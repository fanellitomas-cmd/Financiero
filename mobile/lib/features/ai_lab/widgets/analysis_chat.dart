import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../data/ai_lab_models.dart';
import '../presentation/ai_lab_controller.dart';

/// Hilo de conversación sobre los estados contables del activo.
///
/// El historial lo administra el CLIENTE: cada pregunta viaja con el hilo que el backend devolvió en
/// el turno anterior, y el servidor no lo persiste. Eso tiene una consecuencia que la UI hace
/// explícita con el botón de limpiar: la conversación vive mientras la pantalla esté abierta.
///
/// Las preguntas sugeridas no son decoración. Un campo de texto vacío frente a un balance no le dice
/// al usuario qué se le puede preguntar a esto, y las tres sugerencias son las preguntas que los
/// bloques de arriba ya tienen contestadas con números — así la primera respuesta que ve es una que
/// puede verificar contra la pantalla.
class AnalysisChat extends ConsumerStatefulWidget {
  const AnalysisChat({super.key, required this.analysis});

  final FinancialAnalysisResponse analysis;

  static const suggestions = <String>[
    '¿De dónde viene el ROE?',
    '¿La deuda es manejable?',
    '¿La ganancia se convierte en caja?',
  ];

  @override
  ConsumerState<AnalysisChat> createState() => _AnalysisChatState();
}

class _AnalysisChatState extends ConsumerState<AnalysisChat> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send(String question) async {
    if (question.trim().isEmpty) return;
    _controller.clear();
    await ref.read(analysisControllerProvider.notifier).ask(question);
    if (!mounted) return;
    // Se baja al final después de responder: el turno nuevo entra abajo y sin esto queda fuera de
    // vista justo cuando es lo único que el usuario quiere leer.
    if (_scrollController.hasClients) {
      await _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(analysisControllerProvider);
    final history = widget.analysis.history;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.forum_outlined, size: 16, color: AppTheme.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Preguntale a los estados contables',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (history.isNotEmpty)
              TextButton.icon(
                onPressed: state.isBusy
                    ? null
                    : () => ref
                        .read(analysisControllerProvider.notifier)
                        .clearConversation(),
                icon: const Icon(Icons.restart_alt, size: 15),
                label: const Text('Reiniciar', style: TextStyle(fontSize: 11)),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (history.isEmpty)
          _EmptyThread(analysis: widget.analysis)
        else
          Container(
            constraints: const BoxConstraints(maxHeight: 420),
            decoration: BoxDecoration(
              color: AppTheme.surfaceSunken,
              borderRadius: BorderRadius.circular(AppTheme.radius),
              border: Border.all(color: AppTheme.border),
            ),
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(10),
              shrinkWrap: true,
              itemCount: history.length,
              itemBuilder: (context, index) => _TurnBubble(turn: history[index]),
            ),
          ),
        if (state.isAsking) ...[
          const SizedBox(height: 8),
          const Row(
            children: [
              SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 8),
              Text(
                'Leyendo los estados…',
                style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
              ),
            ],
          ),
        ],
        if (state.errorMessage != null) ...[
          const SizedBox(height: 8),
          Text(
            state.errorMessage!,
            style: const TextStyle(color: AppTheme.bearish, fontSize: 11.5),
          ),
        ],
        const SizedBox(height: 10),
        _Composer(
          controller: _controller,
          enabled: !state.isBusy,
          onSend: _send,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final suggestion in AnalysisChat.suggestions)
              ActionChip(
                label: Text(suggestion, style: const TextStyle(fontSize: 11)),
                onPressed: state.isBusy ? null : () => _send(suggestion),
              ),
          ],
        ),
      ],
    );
  }
}

class _EmptyThread extends StatelessWidget {
  const _EmptyThread({required this.analysis});

  final FinancialAnalysisResponse analysis;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: AppTheme.border),
      ),
      child: Text(
        'El hilo arranca vacío. Las respuestas se apoyan en los estados contables de '
        '${analysis.ticker} que están arriba: si un dato no está ahí, el analista lo va a decir en '
        'vez de estimarlo.',
        style: const TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.45),
      ),
    );
  }
}

class _TurnBubble extends StatelessWidget {
  const _TurnBubble({required this.turn});

  final ConversationTurn turn;

  @override
  Widget build(BuildContext context) {
    final isUser = turn.isUser;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: isUser
              ? AppTheme.accent.withValues(alpha: 0.14)
              : AppTheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isUser
                ? AppTheme.accent.withValues(alpha: 0.35)
                : AppTheme.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isUser ? 'Vos' : 'Analista contable',
              style: AppTheme.numeric(
                fontSize: 9.5,
                color: isUser ? AppTheme.accent : AppTheme.textMuted,
              ).copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              turn.content,
              style: const TextStyle(fontSize: 12.5, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onSend;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            minLines: 1,
            maxLines: 4,
            maxLength: 4000,
            textInputAction: TextInputAction.send,
            onSubmitted: enabled ? onSend : null,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Preguntá sobre el balance, los márgenes o la caja…',
              counterText: '',
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: enabled ? () => onSend(controller.text) : null,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
          child: const Icon(Icons.send, size: 16),
        ),
      ],
    );
  }
}
