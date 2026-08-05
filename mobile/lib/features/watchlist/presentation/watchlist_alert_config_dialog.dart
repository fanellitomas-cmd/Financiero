import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_error.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../data/watchlist_alert_rule.dart';
import '../data/watchlist_alerts_repository.dart';
import '../data/watchlist_models.dart';
import 'watchlist_alerts_controller.dart';

/// Configuración de las alertas contextuales de un ticker: las tres reglas (`PRICE`,
/// `NEWS_SEVERITY`, `TREND_BREAK`), cada una con su interruptor y sus parámetros.
///
/// Dos decisiones que gobiernan el diseño:
///
///  1. **Sin reglas se recibe todo.** Es el comportamiento por defecto del backend, y el diálogo lo
///     dice arriba de todo: si no lo dijera, un usuario con los tres interruptores apagados
///     supondría que no le va a llegar nada, cuando es exactamente al revés.
///  2. **Apagar y eliminar son cosas distintas.** Apagar (`enabled=false`) conserva los parámetros
///     que el usuario ajustó; eliminar los borra y devuelve el ticker al comportamiento por
///     defecto. Se ofrecen las dos porque silenciar una semana y descartar la configuración no son
///     el mismo gesto.
///
/// Los cambios se aplican al guardar, no al tocar cada control: el usuario tiene que poder ajustar
/// tres parámetros y decidir después, sin que cada slider dispare un PATCH.
class WatchlistAlertConfigDialog extends ConsumerStatefulWidget {
  const WatchlistAlertConfigDialog({super.key, required this.item});

  final WatchlistItem item;

  /// Devuelve `true` si se guardó algún cambio, para que la pantalla refresque.
  static Future<bool> show(BuildContext context, WatchlistItem item) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => WatchlistAlertConfigDialog(item: item),
    );
    return saved ?? false;
  }

  @override
  ConsumerState<WatchlistAlertConfigDialog> createState() =>
      _WatchlistAlertConfigDialogState();
}

class _WatchlistAlertConfigDialogState
    extends ConsumerState<WatchlistAlertConfigDialog> {
  /// Estado local de las tres reglas, por tipo. Se arma una sola vez en `initState` desde lo que ya
  /// hay guardado: si se recalculara en cada `build`, un rebuild (por el provider refrescándose)
  /// pisaría lo que el usuario está editando.
  late final Map<AlertRuleType, _RuleEditState> _states;

  bool _saving = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final existing = ref.read(tickerAlertRulesProvider(widget.item.ticker));
    _states = {
      for (final type in AlertRuleType.values)
        type: _RuleEditState.from(
          type: type,
          rule: existing.where((rule) => rule.alertType == type).firstOrNull,
          currentThresholdPct: widget.item.alertThresholdPct,
        ),
    };
  }

  bool get _anyEnabled => _states.values.any((state) => state.enabled);

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _errorText = null;
    });

    final repository = ref.read(watchlistAlertsRepositoryProvider);
    try {
      for (final state in _states.values) {
        await state.apply(repository, widget.item.ticker);
      }
    } on Object catch (error) {
      setState(() {
        _saving = false;
        _errorText = describeApiError(error);
      });
      return;
    }

    ref.invalidate(watchlistAlertRulesProvider);
    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _delete(AlertRuleType type) async {
    final state = _states[type]!;
    final ruleId = state.ruleId;
    if (ruleId == null) return;

    setState(() {
      _saving = true;
      _errorText = null;
    });
    try {
      await ref.read(watchlistAlertsRepositoryProvider).remove(ruleId);
    } on Object catch (error) {
      setState(() {
        _saving = false;
        _errorText = describeApiError(error);
      });
      return;
    }

    ref.invalidate(watchlistAlertRulesProvider);
    setState(() {
      _saving = false;
      _states[type] = _RuleEditState.from(
        type: type,
        rule: null,
        currentThresholdPct: widget.item.alertThresholdPct,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.notifications_active_outlined,
              size: 18, color: AppTheme.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Alertas de ${widget.item.ticker}',
              style: AppTheme.tickerSymbol.copyWith(fontSize: 16),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DefaultBehaviourNotice(anyEnabled: _anyEnabled),
              const SizedBox(height: 14),
              for (final type in AlertRuleType.values) ...[
                _RuleCard(
                  state: _states[type]!,
                  enabled: !_saving,
                  onChanged: (updated) =>
                      setState(() => _states[type] = updated),
                  onDelete: _states[type]!.ruleId == null
                      ? null
                      : () => _delete(type),
                ),
                if (type != AlertRuleType.values.last)
                  const SizedBox(height: 10),
              ],
              if (_errorText != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorText!,
                  style: const TextStyle(color: AppTheme.bearish, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Guardar'),
        ),
      ],
    );
  }
}

/// Qué pasa hoy con este ticker. Cambia de texto según haya o no reglas activas porque son dos
/// situaciones opuestas que sin este aviso se ven igual (tres interruptores apagados).
class _DefaultBehaviourNotice extends StatelessWidget {
  const _DefaultBehaviourNotice({required this.anyEnabled});

  final bool anyEnabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            anyEnabled ? Icons.filter_alt : Icons.notifications_none,
            size: 16,
            color: anyEnabled ? AppTheme.accent : AppTheme.textMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              anyEnabled
                  ? 'Solo vas a recibir avisos que cumplan alguna de las reglas activas.'
                  : 'Sin reglas activas recibís TODOS los avisos que el agente genere sobre '
                      'este activo. Activá una para filtrarlos.',
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Estado editable de una regla: lo que hay guardado más lo que el usuario está tocando.
class _RuleEditState {
  const _RuleEditState({
    required this.ruleId,
    required this.draft,
    required this.originallyExisted,
    required this.originallyEnabled,
  });

  factory _RuleEditState.from({
    required AlertRuleType type,
    required WatchlistAlertRule? rule,
    required double currentThresholdPct,
  }) {
    if (rule == null) {
      return _RuleEditState(
        ruleId: null,
        // Arranca apagada pero con los defaults ya cargados: al encender el interruptor el
        // formulario muestra exactamente lo que se va a guardar, no campos vacíos.
        draft: WatchlistAlertRuleDraft.defaults(
          type,
          currentThresholdPct: currentThresholdPct,
        ).copyWith(enabled: false),
        originallyExisted: false,
        originallyEnabled: false,
      );
    }
    return _RuleEditState(
      ruleId: rule.id,
      draft: WatchlistAlertRuleDraft.fromRule(rule),
      originallyExisted: true,
      originallyEnabled: rule.enabled,
    );
  }

  final String? ruleId;
  final WatchlistAlertRuleDraft draft;
  final bool originallyExisted;
  final bool originallyEnabled;

  AlertRuleType get type => draft.alertType;
  bool get enabled => draft.enabled;

  _RuleEditState withDraft(WatchlistAlertRuleDraft updated) => _RuleEditState(
        ruleId: ruleId,
        draft: updated,
        originallyExisted: originallyExisted,
        originallyEnabled: originallyEnabled,
      );

  /// Guarda esta regla si hace falta.
  ///
  /// Una regla que nunca existió y sigue apagada NO se crea: crear filas apagadas para las tres
  /// reglas de cada ticker llenaría la tabla de configuración que nadie pidió, y "sin regla" ya es
  /// un estado con significado propio (recibir todo).
  Future<void> apply(
    WatchlistAlertsRepository repository,
    String ticker,
  ) async {
    if (!originallyExisted) {
      if (!enabled) return;
      await repository.create(ticker, draft);
      return;
    }
    await repository.update(ruleId!, draft);
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({
    required this.state,
    required this.enabled,
    required this.onChanged,
    required this.onDelete,
  });

  final _RuleEditState state;

  /// `false` mientras se guarda, para que no se pueda editar en el medio de un request.
  final bool enabled;
  final ValueChanged<_RuleEditState> onChanged;
  final VoidCallback? onDelete;

  void _update(WatchlistAlertRuleDraft draft) =>
      onChanged(state.withDraft(draft));

  @override
  Widget build(BuildContext context) {
    final isOn = state.enabled;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSunken,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color:
              isOn ? AppTheme.accent.withValues(alpha: 0.45) : AppTheme.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state.type.displayName,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      state.type.description,
                      style: const TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 11,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: isOn,
                onChanged: enabled
                    ? (value) => _update(state.draft.copyWith(enabled: value))
                    : null,
              ),
            ],
          ),
          if (isOn) ...[
            const SizedBox(height: 8),
            const Divider(height: 1, color: AppTheme.border),
            const SizedBox(height: 12),
            switch (state.type) {
              AlertRuleType.price => _PriceFields(
                  draft: state.draft,
                  enabled: enabled,
                  onChanged: _update,
                ),
              AlertRuleType.newsSeverity => _NewsFields(
                  draft: state.draft,
                  enabled: enabled,
                  onChanged: _update,
                ),
              AlertRuleType.trendBreak => _TrendFields(
                  draft: state.draft,
                  enabled: enabled,
                  onChanged: _update,
                ),
            },
          ],
          if (onDelete != null) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: enabled ? onDelete : null,
                icon: const Icon(Icons.delete_outline, size: 15),
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.textMuted,
                  visualDensity: VisualDensity.compact,
                ),
                label: const Text('Eliminar regla',
                    style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PriceFields extends StatelessWidget {
  const _PriceFields({
    required this.draft,
    required this.enabled,
    required this.onChanged,
  });

  final WatchlistAlertRuleDraft draft;
  final bool enabled;
  final ValueChanged<WatchlistAlertRuleDraft> onChanged;

  @override
  Widget build(BuildContext context) {
    final value = draft.thresholdPct ?? kDefaultThresholdPct;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(
          label: 'Umbral de variación',
          // El valor va en el label y no solo en el slider: es el dato que el usuario está
          // ajustando, y buscarlo abajo del pulgar del slider es peor que leerlo en el título.
          value: '±${value.toStringAsFixed(1)}%',
        ),
        Slider(
          // Máximo en 20% y no en 100: un umbral del 60% no dispararía nunca en una acción, así
          // que la mitad del recorrido del slider sería inútil y la parte útil (2-8%) quedaría
          // comprimida en unos pocos píxeles.
          min: 0.5,
          max: 20,
          divisions: 39,
          value: value.clamp(0.5, 20),
          label: '${value.toStringAsFixed(1)}%',
          onChanged: enabled
              ? (updated) => onChanged(draft.copyWith(thresholdPct: updated))
              : null,
        ),
        const _FieldHint(
          'Cubre las dos direcciones: se avisa tanto si sube como si baja más que el umbral.',
        ),
      ],
    );
  }
}

class _NewsFields extends StatelessWidget {
  const _NewsFields({
    required this.draft,
    required this.enabled,
    required this.onChanged,
  });

  final WatchlistAlertRuleDraft draft;
  final bool enabled;
  final ValueChanged<WatchlistAlertRuleDraft> onChanged;

  /// Se ofrece de Media para arriba. `Baja` existe en el backend pero no se ofrece acá porque una
  /// regla de severidad mínima baja es equivalente a no tener regla — el usuario creería estar
  /// filtrando algo cuando no filtra nada. Si una regla ya guardada la tiene (creada por API), se
  /// incluye igual para no romper el desplegable.
  List<AlertSeverity> _options(AlertSeverity current) {
    const offered = [
      AlertSeverity.medium,
      AlertSeverity.high,
      AlertSeverity.critical,
    ];
    return offered.contains(current) ? offered : [current, ...offered];
  }

  @override
  Widget build(BuildContext context) {
    final severity = draft.minSeverity ?? kDefaultMinSeverity;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _FieldLabel(label: 'Severidad mínima'),
        const SizedBox(height: 6),
        DropdownButtonFormField<AlertSeverity>(
          initialValue: severity,
          isDense: true,
          items: [
            for (final option in _options(severity))
              DropdownMenuItem(
                value: option,
                child: Text(option.displayName,
                    style: const TextStyle(fontSize: 13)),
              ),
          ],
          onChanged: enabled
              ? (updated) => onChanged(
                    updated == null
                        ? draft
                        : draft.copyWith(minSeverity: updated),
                  )
              : null,
        ),
        const SizedBox(height: 10),
        // `Row` + `Switch` y no `SwitchListTile`: un `ListTile` pinta su fondo y su ripple sobre el
        // `Material` más cercano, y acá el contenedor decorado de la card queda por encima — el
        // toque se vería sin ninguna respuesta visual (Flutter lo avisa con un assert).
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Solo si la lectura es negativa',
                      style: TextStyle(fontSize: 13)),
                  SizedBox(height: 2),
                  Text(
                    'Exige que el análisis concluya deterioro real o proyecte baja en el corto '
                    'plazo, no solo que la noticia sea grave.',
                    style: TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: draft.requireNegativeSentiment ?? false,
              onChanged: enabled
                  ? (value) =>
                      onChanged(draft.copyWith(requireNegativeSentiment: value))
                  : null,
            ),
          ],
        ),
      ],
    );
  }
}

class _TrendFields extends StatelessWidget {
  const _TrendFields({
    required this.draft,
    required this.enabled,
    required this.onChanged,
  });

  final WatchlistAlertRuleDraft draft;
  final bool enabled;
  final ValueChanged<WatchlistAlertRuleDraft> onChanged;

  @override
  Widget build(BuildContext context) {
    final horizon = draft.trendHorizon ?? kDefaultTrendHorizon;
    final direction = draft.trendDirection ?? kDefaultTrendDirection;
    final probability = draft.minProbabilityPct ?? kDefaultMinProbabilityPct;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _FieldLabel(label: 'Horizonte'),
        const SizedBox(height: 6),
        DropdownButtonFormField<TrendHorizon>(
          initialValue: horizon,
          isDense: true,
          items: [
            for (final option in TrendHorizon.values)
              DropdownMenuItem(
                value: option,
                child: Text(option.displayName,
                    style: const TextStyle(fontSize: 13)),
              ),
          ],
          onChanged: enabled
              ? (updated) => onChanged(
                    updated == null
                        ? draft
                        : draft.copyWith(trendHorizon: updated),
                  )
              : null,
        ),
        const SizedBox(height: 12),
        const _FieldLabel(label: 'Dirección del quiebre'),
        const SizedBox(height: 6),
        DropdownButtonFormField<TrendBreakDirection>(
          initialValue: direction,
          isDense: true,
          items: [
            for (final option in TrendBreakDirection.values)
              DropdownMenuItem(
                value: option,
                child: Text(option.displayName,
                    style: const TextStyle(fontSize: 13)),
              ),
          ],
          onChanged: enabled
              ? (updated) => onChanged(
                    updated == null
                        ? draft
                        : draft.copyWith(trendDirection: updated),
                  )
              : null,
        ),
        const SizedBox(height: 12),
        _FieldLabel(
          label: 'Probabilidad mínima',
          value: '${probability.toStringAsFixed(0)}%',
        ),
        Slider(
          // Desde 30%: por debajo de eso el escenario ni siquiera es el más probable de los tres, y
          // avisar por él sería avisar por cualquier cosa.
          min: 30,
          max: 90,
          divisions: 12,
          value: probability.clamp(30, 90),
          label: '${probability.toStringAsFixed(0)}%',
          onChanged: enabled
              ? (updated) =>
                  onChanged(draft.copyWith(minProbabilityPct: updated))
              : null,
        ),
        const _FieldHint(
          'Las proyecciones que el propio agente marca como de baja confianza no disparan aviso, '
          'sin importar este número.',
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.label, this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
        ),
        if (value != null)
          Text(
            value!,
            style: AppTheme.numeric(fontSize: 13, color: AppTheme.accent)
                .copyWith(fontWeight: FontWeight.bold),
          ),
      ],
    );
  }
}

class _FieldHint extends StatelessWidget {
  const _FieldHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppTheme.textMuted,
        fontSize: 11,
        height: 1.35,
      ),
    );
  }
}
