import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/alerts/presentation/alerts_screen.dart';
import '../../features/asset_detail/presentation/asset_detail_screen.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/chat/presentation/chat_screen.dart';
import '../../features/dashboard/presentation/dashboard_screen.dart';
import '../../features/watchlist/data/watchlist_models.dart';
import '../../features/watchlist/presentation/watchlist_screen.dart';
import '../providers.dart';
import '../widgets/app_shell.dart';

/// Puente entre el `AuthState` de Riverpod y `GoRouter.refreshListenable`: go_router espera un
/// `Listenable` clásico, no un provider — este `ChangeNotifier` solo reenvía el evento cada vez
/// que cambia `authControllerProvider`, para que `redirect` se reevalúe sin reconstruir el
/// `GoRouter` entero en cada cambio de sesión (reconstruirlo perdería el historial de navegación).
class _AuthRefreshNotifier extends ChangeNotifier {
  _AuthRefreshNotifier(Ref ref) {
    ref.listen(authControllerProvider, (previous, next) {
      if (previous?.isAuthenticated != next.isAuthenticated) {
        notifyListeners();
      }
    });
  }
}

final goRouterProvider = Provider<GoRouter>((ref) {
  final refreshNotifier = _AuthRefreshNotifier(ref);
  ref.onDispose(refreshNotifier.dispose);

  return GoRouter(
    initialLocation: '/dashboard',
    refreshListenable: refreshNotifier,
    redirect: (context, state) {
      final authState = ref.read(authControllerProvider);
      final isLoggingIn = state.matchedLocation == '/login';
      if (!authState.isAuthenticated && !isLoggingIn) return '/login';
      if (authState.isAuthenticated && isLoggingIn) return '/dashboard';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
              path: '/dashboard',
              builder: (context, state) => const DashboardScreen()),
          GoRoute(
              path: '/chat', builder: (context, state) => const ChatScreen()),
          GoRoute(
              path: '/watchlist',
              builder: (context, state) => const WatchlistScreen()),
        ],
      ),
      GoRoute(
        path: '/asset/:ticker',
        builder: (context, state) {
          final assetTypeParam = state.uri.queryParameters['assetType'];
          return AssetDetailScreen(
            ticker: state.pathParameters['ticker']!,
            // Default a STOCK si algún call site viejo no manda el query param — nunca
            // debería pasar en pantallas nuevas, pero evita un crash por un link externo.
            assetType: assetTypeParam != null
                ? AssetTypeJson.fromJson(assetTypeParam)
                : AssetType.stock,
          );
        },
      ),
      GoRoute(
          path: '/alerts', builder: (context, state) => const AlertsScreen()),
    ],
  );
});
