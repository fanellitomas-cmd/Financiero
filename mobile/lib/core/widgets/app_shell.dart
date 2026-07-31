import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Shell con la bottom nav de las 3 pantallas principales (Dashboard/Chat/Watchlist). La
/// Ficha de un activo (`/asset/:ticker`) se navega apilada por encima, fuera del shell — no es
/// una pestaña, se llega a ella desde el Dashboard/Watchlist/Chat.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  static const _tabs = ['/dashboard', '/chat', '/watchlist'];

  int _currentIndex(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    final index = _tabs.indexOf(location);
    return index == -1 ? 0 : index;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex(context),
        onDestinationSelected: (index) => context.go(_tabs[index]),
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
