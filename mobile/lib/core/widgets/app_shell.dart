import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/settings/presentation/exchange_onboarding_dialog.dart';
import '../providers.dart';

/// Shell con la bottom nav de las 3 pantallas principales (Dashboard/Chat/Watchlist). La
/// Ficha de un activo (`/asset/:ticker`) se navega apilada por encima, fuera del shell — no es
/// una pestaña, se llega a ella desde el Dashboard/Watchlist/Chat.
///
/// También es el punto donde se dispara el onboarding de bolsa: al envolver las tres pestañas,
/// el diálogo aparece sin importar en cuál caiga el usuario después de loguearse, y una sola
/// vez (no una por pantalla, como pasaría si viviera en el Dashboard).
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  static const _tabs = ['/dashboard', '/chat', '/watchlist'];

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  bool _onboardingShown = false;

  int _currentIndex(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    final index = AppShell._tabs.indexOf(location);
    return index == -1 ? 0 : index;
  }

  void _maybeShowOnboarding() {
    if (_onboardingShown) return;
    if (!ref.read(exchangeControllerProvider).needsOnboarding) return;

    // El flag se marca antes del await: sin esto, un rebuild mientras el diálogo está
    // abierto lo volvería a abrir apilado encima de sí mismo.
    _onboardingShown = true;
    // El diálogo no puede abrirse durante build — se posterga al frame siguiente.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ExchangeOnboardingDialog.show(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    // `watch` (no `read`) para que esto se reevalúe cuando termine de cargar la preferencia
    // desde disco: en el primer build `isLoading` todavía es true y no se sabe si falta.
    ref.watch(exchangeControllerProvider);
    _maybeShowOnboarding();

    return Scaffold(
      body: widget.child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex(context),
        onDestinationSelected: (index) => context.go(AppShell._tabs[index]),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chat',
          ),
          NavigationDestination(
            icon: Icon(Icons.visibility_outlined),
            selectedIcon: Icon(Icons.visibility),
            label: 'Watchlist',
          ),
        ],
      ),
    );
  }
}
