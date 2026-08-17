import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/settings/presentation/exchange_onboarding_dialog.dart';
import '../layout/breakpoints.dart';
import '../providers.dart';
import '../../features/auth/presentation/account_button.dart';
import '../theme/app_theme.dart';

/// Shell de las 3 pantallas principales (Dashboard/Chat/Watchlist), adaptativo: barra inferior
/// en mobile, `NavigationRail` lateral desde `Breakpoints.desktop`. En pantallas anchas una
/// barra inferior desperdicia el alto útil y deja los destinos lejos del contenido; el rail los
/// pone donde el ojo ya está.
///
/// También es el punto donde se dispara el onboarding de bolsa: al envolver las tres pestañas,
/// el diálogo aparece sin importar en cuál caiga el usuario después de loguearse, y una sola
/// vez (no una por pantalla, como pasaría si viviera en el Dashboard).
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  static const _destinations = <_ShellDestination>[
    _ShellDestination(
      route: '/dashboard',
      label: 'Dashboard',
      icon: Icons.dashboard_outlined,
      selectedIcon: Icons.dashboard,
    ),
    _ShellDestination(
      route: '/chat',
      label: 'Chat',
      icon: Icons.chat_bubble_outline,
      selectedIcon: Icons.chat_bubble,
    ),
    _ShellDestination(
      route: '/watchlist',
      label: 'Watchlist',
      icon: Icons.visibility_outlined,
      selectedIcon: Icons.visibility,
    ),
    // El Hub Corporativo es de primer nivel porque su pregunta no arranca en un activo sino en el
    // calendario: "quién reporta esta semana" no se puede llegar a preguntar desde la ficha de un
    // símbolo, que es lo que quedaría si viviera adentro de ella.
    _ShellDestination(
      route: '/corporate',
      label: 'Corporativo',
      icon: Icons.business_center_outlined,
      selectedIcon: Icons.business_center,
    ),
    // El Lab es un destino de primer nivel y no una sub-pantalla de la Watchlist: las notas no son
    // de los activos que seguís sino tuyas, y varias no tienen ticker asociado. Enterrarlo dentro de
    // la Watchlist volvería inalcanzables justamente esas.
    _ShellDestination(
      route: '/lab',
      label: 'Lab',
      icon: Icons.science_outlined,
      selectedIcon: Icons.science,
    ),
  ];

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _ShellDestination {
  const _ShellDestination({
    required this.route,
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String route;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class _AppShellState extends ConsumerState<AppShell> {
  bool _onboardingShown = false;

  int _currentIndex(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    final index = AppShell._destinations.indexWhere((d) => d.route == location);
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

    final index = _currentIndex(context);
    void goTo(int i) => context.go(AppShell._destinations[i].route);

    if (!context.isDesktop) {
      return Scaffold(
        body: widget.child,
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: goTo,
          destinations: [
            for (final destination in AppShell._destinations)
              NavigationDestination(
                icon: Icon(destination.icon),
                selectedIcon: Icon(destination.selectedIcon),
                label: destination.label,
              ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          _AppNavigationRail(selectedIndex: index, onDestinationSelected: goTo),
          // Borde vertical en vez de sombra: en dark mode la sombra no se percibe y esto es lo
          // que separa visualmente la nav del contenido.
          const VerticalDivider(width: 1, thickness: 1, color: AppTheme.border),
          Expanded(child: widget.child),
        ],
      ),
    );
  }
}

class _AppNavigationRail extends StatelessWidget {
  const _AppNavigationRail({
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    return NavigationRail(
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      // Marca de la app arriba del rail: en escritorio no hay un AppBar único que la muestre,
      // así que sin esto la ventana no tiene identidad.
      leading: const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Icon(Icons.candlestick_chart, size: 28),
      ),
      // Al pie del rail y separado de los destinos: no es un lugar al que se navega, es una acción.
      trailing: const Expanded(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: AccountButton(compact: true),
          ),
        ),
      ),
      destinations: [
        for (final destination in AppShell._destinations)
          NavigationRailDestination(
            icon: Icon(destination.icon),
            selectedIcon: Icon(destination.selectedIcon),
            label: Text(destination.label),
          ),
      ],
    );
  }
}
