import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // Requiere `flutterfire configure` (genera `firebase_options.dart`) o
    // google-services.json/GoogleService-Info.plist ya agregados al proyecto nativo. Se
    // degrada explícito en vez de crashear: el resto de la app funciona sin push hasta que
    // Firebase esté configurado (ver app/core/config.py del lado del backend, mismo patrón).
    //
    // El timeout es deliberado: en Web, `Firebase.initializeApp()` carga el SDK de Firebase
    // desde un `<script>` externo (gstatic.com) — si esa red falla o cuelga (firewall,
    // offline, CDN caído), la promesa de JS interop puede no resolver NUNCA, y sin timeout
    // `runApp()` no se llama jamás y la app queda en blanco sin ningún error visible.
    await Firebase.initializeApp().timeout(const Duration(seconds: 5));
  } on Object catch (error) {
    debugPrint(
        'Firebase no inicializado: $error (¿falta flutterfire configure?)');
  }

  runApp(const ProviderScope(child: FinancieroApp()));
}

class FinancieroApp extends ConsumerWidget {
  const FinancieroApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(goRouterProvider);

    return MaterialApp.router(
      title: 'Financiero',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      routerConfig: router,
    );
  }
}
