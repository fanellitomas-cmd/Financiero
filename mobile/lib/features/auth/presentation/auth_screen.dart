import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/theme/app_theme.dart';

/// Entrada a la aplicación: iniciar sesión o crear cuenta.
///
/// Un solo formulario con dos modos en vez de dos pantallas: los campos son casi los mismos y quien
/// se equivocó de modo tiene que poder cambiar sin volver a escribir el email.
///
/// **La validación es del cliente y del servidor, y no son la misma cosa.** Acá se valida lo que se
/// puede saber sin preguntar —que el email tenga forma de email, que la contraseña llegue al mínimo
/// que el backend exige— para no gastar un viaje en un 422 previsible. Lo que solo sabe el servidor
/// —si el email ya está tomado, si el código de invitación es el correcto— se pregunta y se muestra
/// **su** mensaje, no una suposición nuestra.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

enum _Mode { login, register }

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _inviteController = TextEditingController();

  _Mode _mode = _Mode.login;
  bool _rememberMe = true;
  bool _showPassword = false;

  /// Contraseña mínima que acepta `UserCreate` en el backend. Se replica acá para poder avisar antes
  /// de mandar; si allá cambia, este número queda desactualizado y el 422 vuelve a ser la red.
  static const _minPasswordLength = 8;

  bool get _isRegister => _mode == _Mode.register;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _inviteController.dispose();
    super.dispose();
  }

  void _switchMode(_Mode mode) {
    if (_mode == mode) return;
    setState(() => _mode = mode);
    // El error del intento anterior no aplica al modo nuevo: "contraseña incorrecta" no dice nada
    // sobre el registro que el usuario está por hacer.
    ref.read(authControllerProvider.notifier).clearError();
    _formKey.currentState?.reset();
  }

  String? _validateEmail(String? value) {
    final email = value?.trim() ?? '';
    if (email.isEmpty) return 'Escribí tu email.';
    // Deliberadamente laxo: algo@algo.algo. Una regex "completa" de RFC 5322 rechaza direcciones
    // válidas y no acepta ninguna que el servidor no acepte igual, así que el filtro fino queda allá.
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      return 'Ese email no parece válido.';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    final password = value ?? '';
    if (password.isEmpty) return 'Escribí tu contraseña.';
    // El mínimo solo se exige al CREAR la cuenta. Pedírselo al entrar rechazaría de antemano a
    // alguien con una contraseña vieja más corta, sin siquiera preguntarle al servidor.
    if (_isRegister && password.length < _minPasswordLength) {
      return 'Al menos $_minPasswordLength caracteres.';
    }
    return null;
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final controller = ref.read(authControllerProvider.notifier);
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (_isRegister) {
      await controller.register(
        email: email,
        password: password,
        inviteCode: _inviteController.text,
        rememberMe: _rememberMe,
      );
    } else {
      await controller.login(
        email: email,
        password: password,
        rememberMe: _rememberMe,
      );
    }

    if (!mounted) return;
    if (ref.read(authControllerProvider).isAuthenticated) {
      try {
        // Firebase puede no estar inicializado (falta `flutterfire configure`, o falló/colgó al
        // cargar su SDK) — un usuario sin push configurado tiene que poder entrar igual, así que esto
        // se degrada en vez de dejar una excepción sin capturar.
        await ref.read(pushServiceProvider).requestPermissionAndRegister();
      } on Object catch (error) {
        debugPrint('No se pudo registrar el token de push: $error');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);
    final busy = authState.isLoading;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _Brand(),
                  const SizedBox(height: 26),
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(AppTheme.radius),
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _ModeTabs(
                          mode: _mode,
                          enabled: !busy,
                          onChanged: _switchMode,
                        ),
                        const SizedBox(height: 18),
                        Form(
                          key: _formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TextFormField(
                                controller: _emailController,
                                enabled: !busy,
                                keyboardType: TextInputType.emailAddress,
                                autofillHints: const [AutofillHints.email],
                                textInputAction: TextInputAction.next,
                                validator: _validateEmail,
                                decoration: const InputDecoration(
                                  labelText: 'Email',
                                  prefixIcon: Icon(Icons.mail_outline, size: 18),
                                ),
                              ),
                              const SizedBox(height: 14),
                              TextFormField(
                                controller: _passwordController,
                                enabled: !busy,
                                obscureText: !_showPassword,
                                autofillHints: [
                                  _isRegister
                                      ? AutofillHints.newPassword
                                      : AutofillHints.password,
                                ],
                                textInputAction: _isRegister
                                    ? TextInputAction.next
                                    : TextInputAction.done,
                                onFieldSubmitted: (_) => busy ? null : _submit(),
                                validator: _validatePassword,
                                decoration: InputDecoration(
                                  labelText: 'Contraseña',
                                  prefixIcon:
                                      const Icon(Icons.lock_outline, size: 18),
                                  helperText: _isRegister
                                      ? 'Mínimo $_minPasswordLength caracteres.'
                                      : null,
                                  helperStyle: const TextStyle(fontSize: 10.5),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _showPassword
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined,
                                      size: 18,
                                    ),
                                    tooltip: _showPassword
                                        ? 'Ocultar contraseña'
                                        : 'Mostrar contraseña',
                                    onPressed: () => setState(
                                      () => _showPassword = !_showPassword,
                                    ),
                                  ),
                                ),
                              ),
                              if (_isRegister) ...[
                                const SizedBox(height: 14),
                                TextFormField(
                                  controller: _inviteController,
                                  enabled: !busy,
                                  textInputAction: TextInputAction.done,
                                  onFieldSubmitted: (_) =>
                                      busy ? null : _submit(),
                                  decoration: const InputDecoration(
                                    labelText: 'Código de invitación',
                                    prefixIcon:
                                        Icon(Icons.vpn_key_outlined, size: 18),
                                    // No se valida acá: solo el servidor sabe si esta instancia lo
                                    // exige. Marcarlo obligatorio rompería el registro abierto.
                                    helperText:
                                        'Solo si te lo pidieron al compartirte el acceso.',
                                    helperStyle: TextStyle(fontSize: 10.5),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        _RememberMe(
                          value: _rememberMe,
                          enabled: !busy,
                          onChanged: (value) =>
                              setState(() => _rememberMe = value),
                        ),
                        if (authState.errorMessage != null) ...[
                          const SizedBox(height: 12),
                          _ErrorNotice(message: authState.errorMessage!),
                        ],
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: busy ? null : _submit,
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 15),
                          ),
                          child: busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Text(
                                  _isRegister ? 'Crear cuenta' : 'Ingresar',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const _Disclaimer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Icon(Icons.candlestick_chart, size: 40, color: AppTheme.accent),
        const SizedBox(height: 10),
        Text(
          'Financiero',
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        const Text(
          'Watchlist, fichas de inteligencia, laboratorio contable y carteras.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.4),
        ),
      ],
    );
  }
}

class _ModeTabs extends StatelessWidget {
  const _ModeTabs({
    required this.mode,
    required this.enabled,
    required this.onChanged,
  });

  final _Mode mode;
  final bool enabled;
  final ValueChanged<_Mode> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<_Mode>(
      segments: const [
        ButtonSegment(value: _Mode.login, label: Text('Iniciar sesión')),
        ButtonSegment(value: _Mode.register, label: Text('Crear cuenta')),
      ],
      selected: {mode},
      showSelectedIcon: false,
      onSelectionChanged:
          enabled ? (selection) => onChanged(selection.first) : null,
    );
  }
}

/// La casilla de recordar sesión, con su consecuencia escrita al lado.
///
/// El texto de abajo cambia con el valor y no es adorno: "recordarme" y "no recordarme" describen dos
/// conductas distintas del token, y sin decirlo la casilla se lee como una preferencia sin efecto.
class _RememberMe extends StatelessWidget {
  const _RememberMe({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 36,
              height: 36,
              child: Checkbox(
                value: value,
                onChanged: enabled ? (next) => onChanged(next ?? false) : null,
              ),
            ),
            Expanded(
              child: GestureDetector(
                onTap: enabled ? () => onChanged(!value) : null,
                child: const Text(
                  'Recordar mi sesión',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text(
            value
                ? 'Vas a seguir dentro la próxima vez que abras la app.'
                : 'Al cerrar la pestaña vas a tener que entrar de nuevo.',
            style: const TextStyle(
              fontSize: 10.5,
              color: AppTheme.textMuted,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

/// El error tal como lo explicó el backend.
class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.bearish.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.bearish.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 15, color: AppTheme.bearish),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.bearish,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'Los análisis de la app son informativos y no son recomendaciones de inversión.',
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 10.5, color: AppTheme.textMuted, height: 1.4),
    );
  }
}
