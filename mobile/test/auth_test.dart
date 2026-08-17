import 'package:dio/dio.dart';
import 'package:financiero_app/core/providers.dart';
import 'package:financiero_app/core/theme/app_theme.dart';
import 'package:financiero_app/features/auth/data/auth_repository.dart';
import 'package:financiero_app/features/auth/presentation/account_button.dart';
import 'package:financiero_app/features/auth/presentation/auth_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Doble del repositorio. Registra lo que recibió y falla con la `DioException` que le indiquen, para
/// poder verificar que el mensaje que se muestra es el que MANDÓ EL BACKEND y no uno inventado acá.
class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository({this.alreadyAuthenticated = false});

  bool alreadyAuthenticated;
  DioException? registerError;
  DioException? loginError;

  final List<Map<String, Object?>> registerCalls = [];
  final List<Map<String, Object?>> loginCalls = [];
  int logoutCalls = 0;

  @override
  Future<bool> isAuthenticated() async => alreadyAuthenticated;

  @override
  Future<void> register({
    required String email,
    required String password,
    String? inviteCode,
  }) async {
    registerCalls.add({
      'email': email,
      'password': password,
      'inviteCode': inviteCode,
    });
    final failure = registerError;
    if (failure != null) throw failure;
  }

  @override
  Future<void> login({
    required String email,
    required String password,
    bool rememberMe = true,
  }) async {
    loginCalls.add({
      'email': email,
      'password': password,
      'rememberMe': rememberMe,
    });
    final failure = loginError;
    if (failure != null) throw failure;
    alreadyAuthenticated = true;
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
    alreadyAuthenticated = false;
  }
}

/// Una respuesta de error del backend con su `detail`, igual que la que produce FastAPI.
DioException _httpError(int status, String detail) => DioException(
      requestOptions: RequestOptions(path: '/auth'),
      response: Response(
        requestOptions: RequestOptions(path: '/auth'),
        statusCode: status,
        data: {'detail': detail},
      ),
    );

DioException _networkError() => DioException(
      requestOptions: RequestOptions(path: '/auth'),
      type: DioExceptionType.connectionError,
    );

ProviderContainer _container(_FakeAuthRepository repository) {
  final container = ProviderContainer(
    overrides: [authRepositoryProvider.overrideWithValue(repository)],
  );
  addTearDown(container.dispose);
  return container;
}

/// Espera a que el chequeo inicial de sesión termine: el controller arranca con `isLoading: true` y
/// resuelve en un microtask.
Future<void> _settled(ProviderContainer container) async {
  container.read(authControllerProvider);
  await Future<void>.delayed(Duration.zero);
}

Future<void> _pumpAuthScreen(
  WidgetTester tester,
  _FakeAuthRepository repository, {
  Size size = const Size(900, 1200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [authRepositoryProvider.overrideWithValue(repository)],
      child: MaterialApp(theme: AppTheme.dark, home: const AuthScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _fieldByLabel(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byType(TextFormField),
    );

void main() {
  // --- Controller -------------------------------------------------------------------------------

  group('AuthController', () {
    test('arranca cargando hasta saber si hay token guardado', () async {
      // Sin esto el router redirigiría a /auth en el primer frame y una sesión guardada parpadearía
      // como ausente.
      final container = _container(_FakeAuthRepository());

      expect(container.read(authControllerProvider).isLoading, isTrue);

      await _settled(container);
      expect(container.read(authControllerProvider).isLoading, isFalse);
    });

    test('una sesión guardada queda autenticada sin pedir credenciales', () async {
      final container = _container(
        _FakeAuthRepository(alreadyAuthenticated: true),
      );
      await _settled(container);

      expect(container.read(authControllerProvider).isAuthenticated, isTrue);
    });

    test('el login exitoso autentica', () async {
      final repository = _FakeAuthRepository();
      final container = _container(repository);
      await _settled(container);

      await container
          .read(authControllerProvider.notifier)
          .login(email: 'a@b.com', password: 'supersecreta1');

      expect(container.read(authControllerProvider).isAuthenticated, isTrue);
      expect(container.read(authControllerProvider).errorMessage, isNull);
    });

    test('el mensaje de error es el del BACKEND, no uno inventado', () async {
      // Es el cambio central: la versión anterior contestaba "¿el email ya existe?" ante cualquier
      // fallo del registro, incluido un código de invitación equivocado.
      final repository = _FakeAuthRepository()
        ..registerError = _httpError(403, 'Esta instancia necesita un código.');
      final container = _container(repository);
      await _settled(container);

      await container
          .read(authControllerProvider.notifier)
          .register(email: 'a@b.com', password: 'supersecreta1');

      expect(
        container.read(authControllerProvider).errorMessage,
        'Esta instancia necesita un código.',
      );
    });

    test('un email tomado se distingue de un código equivocado', () async {
      final repository = _FakeAuthRepository()
        ..registerError =
            _httpError(409, 'Ya existe una cuenta con ese email.');
      final container = _container(repository);
      await _settled(container);

      await container
          .read(authControllerProvider.notifier)
          .register(email: 'a@b.com', password: 'supersecreta1');

      expect(
        container.read(authControllerProvider).errorMessage,
        contains('Ya existe una cuenta'),
      );
    });

    test('un fallo de red no se reporta como credenciales inválidas', () async {
      final repository = _FakeAuthRepository()..loginError = _networkError();
      final container = _container(repository);
      await _settled(container);

      await container
          .read(authControllerProvider.notifier)
          .login(email: 'a@b.com', password: 'supersecreta1');

      final message = container.read(authControllerProvider).errorMessage;
      expect(message, contains('No se pudo conectar'));
      expect(message, isNot(contains('incorrect')));
    });

    test('un registro fallido NO intenta loguear', () async {
      final repository = _FakeAuthRepository()
        ..registerError = _httpError(409, 'Ya existe una cuenta con ese email.');
      final container = _container(repository);
      await _settled(container);

      await container
          .read(authControllerProvider.notifier)
          .register(email: 'a@b.com', password: 'supersecreta1');

      expect(repository.loginCalls, isEmpty);
    });

    test('si el alta sale bien y el login falla, se dice que la cuenta existe',
        () async {
      // Decir "no se pudo registrar" mandaría a crear una cuenta que ya está creada.
      final repository = _FakeAuthRepository()..loginError = _networkError();
      final container = _container(repository);
      await _settled(container);

      await container
          .read(authControllerProvider.notifier)
          .register(email: 'a@b.com', password: 'supersecreta1');

      expect(
        container.read(authControllerProvider).errorMessage,
        contains('La cuenta se creó'),
      );
    });

    test('el registro reenvía el código de invitación', () async {
      final repository = _FakeAuthRepository();
      final container = _container(repository);
      await _settled(container);

      await container.read(authControllerProvider.notifier).register(
            email: 'a@b.com',
            password: 'supersecreta1',
            inviteCode: 'pase',
          );

      expect(repository.registerCalls.single['inviteCode'], 'pase');
    });

    test('"recordarme" viaja hasta el repositorio', () async {
      final repository = _FakeAuthRepository();
      final container = _container(repository);
      await _settled(container);

      await container.read(authControllerProvider.notifier).login(
            email: 'a@b.com',
            password: 'supersecreta1',
            rememberMe: false,
          );

      expect(repository.loginCalls.single['rememberMe'], isFalse);
    });

    test('un login exitoso limpia el error del intento anterior', () async {
      final repository = _FakeAuthRepository()
        ..loginError = _httpError(401, 'Email o contraseña inválidos.');
      final container = _container(repository);
      await _settled(container);
      final controller = container.read(authControllerProvider.notifier);

      await controller.login(email: 'a@b.com', password: 'mala');
      expect(container.read(authControllerProvider).errorMessage, isNotNull);

      repository.loginError = null;
      await controller.login(email: 'a@b.com', password: 'supersecreta1');
      expect(container.read(authControllerProvider).errorMessage, isNull);
    });

    test('el logout desautentica y limpia el token', () async {
      final repository = _FakeAuthRepository(alreadyAuthenticated: true);
      final container = _container(repository);
      await _settled(container);

      await container.read(authControllerProvider.notifier).logout();

      expect(container.read(authControllerProvider).isAuthenticated, isFalse);
      expect(repository.logoutCalls, 1);
    });

    test('clearError borra el mensaje sin desautenticar', () async {
      final repository = _FakeAuthRepository()..loginError = _networkError();
      final container = _container(repository);
      await _settled(container);
      final controller = container.read(authControllerProvider.notifier);

      await controller.login(email: 'a@b.com', password: 'supersecreta1');
      expect(container.read(authControllerProvider).errorMessage, isNotNull);

      controller.clearError();
      expect(container.read(authControllerProvider).errorMessage, isNull);
    });
  });

  // --- Pantalla ---------------------------------------------------------------------------------

  group('AuthScreen', () {
    testWidgets('arranca en iniciar sesión, sin el campo de invitación',
        (tester) async {
      await _pumpAuthScreen(tester, _FakeAuthRepository());

      expect(find.text('Ingresar'), findsOneWidget);
      expect(find.text('Código de invitación'), findsNothing);
    });

    testWidgets('al pasar a crear cuenta aparece el código de invitación',
        (tester) async {
      await _pumpAuthScreen(tester, _FakeAuthRepository());

      await tester.tap(find.text('Crear cuenta').first);
      await tester.pumpAndSettle();

      expect(find.text('Código de invitación'), findsOneWidget);
      expect(
        find.textContaining('Solo si te lo pidieron'),
        findsOneWidget,
      );
    });

    testWidgets('un email inválido no llega al backend', (tester) async {
      final repository = _FakeAuthRepository();
      await _pumpAuthScreen(tester, repository);

      await tester.enterText(_fieldByLabel('Email'), 'no-es-un-email');
      await tester.enterText(_fieldByLabel('Contraseña'), 'supersecreta1');
      await tester.tap(find.widgetWithText(FilledButton, 'Ingresar'));
      await tester.pumpAndSettle();

      expect(find.text('Ese email no parece válido.'), findsOneWidget);
      expect(repository.loginCalls, isEmpty);
    });

    testWidgets('los campos vacíos se señalan sin pedir nada al servidor',
        (tester) async {
      final repository = _FakeAuthRepository();
      await _pumpAuthScreen(tester, repository);

      await tester.tap(find.widgetWithText(FilledButton, 'Ingresar'));
      await tester.pumpAndSettle();

      expect(find.text('Escribí tu email.'), findsOneWidget);
      expect(find.text('Escribí tu contraseña.'), findsOneWidget);
      expect(repository.loginCalls, isEmpty);
    });

    testWidgets('el mínimo de contraseña se exige al CREAR, no al entrar',
        (tester) async {
      // Exigirlo al entrar rechazaría de antemano a alguien con una contraseña vieja más corta.
      final repository = _FakeAuthRepository();
      await _pumpAuthScreen(tester, repository);

      await tester.enterText(_fieldByLabel('Email'), 'a@b.com');
      await tester.enterText(_fieldByLabel('Contraseña'), 'corta');
      await tester.tap(find.widgetWithText(FilledButton, 'Ingresar'));
      await tester.pumpAndSettle();

      // Al entrar, pasa y se le pregunta al servidor.
      expect(repository.loginCalls, hasLength(1));
    });

    testWidgets('al crear cuenta, una contraseña corta se rechaza acá',
        (tester) async {
      final repository = _FakeAuthRepository();
      await _pumpAuthScreen(tester, repository);

      await tester.tap(find.text('Crear cuenta').first);
      await tester.pumpAndSettle();
      await tester.enterText(_fieldByLabel('Email'), 'a@b.com');
      await tester.enterText(_fieldByLabel('Contraseña'), 'corta');
      await tester.tap(find.widgetWithText(FilledButton, 'Crear cuenta'));
      await tester.pumpAndSettle();

      expect(find.text('Al menos 8 caracteres.'), findsOneWidget);
      expect(repository.registerCalls, isEmpty);
    });

    testWidgets('un login válido llega al backend con lo tipeado',
        (tester) async {
      final repository = _FakeAuthRepository();
      await _pumpAuthScreen(tester, repository);

      await tester.enterText(_fieldByLabel('Email'), '  a@b.com  ');
      await tester.enterText(_fieldByLabel('Contraseña'), 'supersecreta1');
      await tester.tap(find.widgetWithText(FilledButton, 'Ingresar'));
      await tester.pumpAndSettle();

      // El email va sin espacios; la contraseña, tal cual (un espacio puede ser parte de ella).
      expect(repository.loginCalls.single['email'], 'a@b.com');
      expect(repository.loginCalls.single['password'], 'supersecreta1');
    });

    testWidgets('el error del backend se muestra tal cual', (tester) async {
      final repository = _FakeAuthRepository()
        ..loginError = _httpError(401, 'Email o contraseña inválidos.');
      await _pumpAuthScreen(tester, repository);

      await tester.enterText(_fieldByLabel('Email'), 'a@b.com');
      await tester.enterText(_fieldByLabel('Contraseña'), 'supersecreta1');
      await tester.tap(find.widgetWithText(FilledButton, 'Ingresar'));
      await tester.pumpAndSettle();

      expect(find.text('Email o contraseña inválidos.'), findsOneWidget);
    });

    testWidgets('cambiar de modo limpia el error del intento anterior',
        (tester) async {
      final repository = _FakeAuthRepository()
        ..loginError = _httpError(401, 'Email o contraseña inválidos.');
      await _pumpAuthScreen(tester, repository);

      await tester.enterText(_fieldByLabel('Email'), 'a@b.com');
      await tester.enterText(_fieldByLabel('Contraseña'), 'supersecreta1');
      await tester.tap(find.widgetWithText(FilledButton, 'Ingresar'));
      await tester.pumpAndSettle();
      expect(find.text('Email o contraseña inválidos.'), findsOneWidget);

      await tester.tap(find.text('Crear cuenta').first);
      await tester.pumpAndSettle();

      expect(find.text('Email o contraseña inválidos.'), findsNothing);
    });

    testWidgets('recordar sesión viene tildado y explica su consecuencia',
        (tester) async {
      await _pumpAuthScreen(tester, _FakeAuthRepository());

      expect(find.text('Recordar mi sesión'), findsOneWidget);
      expect(
        find.textContaining('seguir dentro la próxima vez'),
        findsOneWidget,
      );
    });

    testWidgets('al destildarlo, el texto dice qué va a pasar', (tester) async {
      // La casilla no es una preferencia decorativa: cambia dónde vive el token.
      await _pumpAuthScreen(tester, _FakeAuthRepository());

      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('cerrar la pestaña vas a tener que entrar de nuevo'),
        findsOneWidget,
      );
    });

    testWidgets('destildado, el login se manda sin recordar', (tester) async {
      final repository = _FakeAuthRepository();
      await _pumpAuthScreen(tester, repository);

      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.enterText(_fieldByLabel('Email'), 'a@b.com');
      await tester.enterText(_fieldByLabel('Contraseña'), 'supersecreta1');
      await tester.tap(find.widgetWithText(FilledButton, 'Ingresar'));
      await tester.pumpAndSettle();

      expect(repository.loginCalls.single['rememberMe'], isFalse);
    });

    testWidgets('la contraseña se puede mostrar y volver a ocultar',
        (tester) async {
      await _pumpAuthScreen(tester, _FakeAuthRepository());

      expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
      await tester.tap(find.byIcon(Icons.visibility_outlined));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
    });

    testWidgets('el aviso de que no es recomendación está a la vista',
        (tester) async {
      await _pumpAuthScreen(tester, _FakeAuthRepository());

      expect(
        find.textContaining('no son recomendaciones de inversión'),
        findsOneWidget,
      );
    });
  });

  // --- Cerrar sesión ----------------------------------------------------------------------------

  group('AccountButton', () {
    Future<void> pump(WidgetTester tester, _FakeAuthRepository repository) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: Scaffold(
              appBar: AppBar(actions: const [AccountButton()]),
              body: const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('ofrece cerrar sesión', (tester) async {
      await pump(tester, _FakeAuthRepository(alreadyAuthenticated: true));

      await tester.tap(find.byType(AccountButton));
      await tester.pumpAndSettle();

      expect(find.text('Cerrar sesión'), findsOneWidget);
    });

    testWidgets('pide confirmación antes de cerrar', (tester) async {
      // Cerrar sesión con un solo toque sobre un ícono de la barra es demasiado fácil sin querer.
      final repository = _FakeAuthRepository(alreadyAuthenticated: true);
      await pump(tester, repository);

      await tester.tap(find.byType(AccountButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cerrar sesión'));
      await tester.pumpAndSettle();

      expect(find.text('¿Cerrar sesión?'), findsOneWidget);
      expect(repository.logoutCalls, 0);
    });

    testWidgets('cancelar no cierra la sesión', (tester) async {
      final repository = _FakeAuthRepository(alreadyAuthenticated: true);
      await pump(tester, repository);

      await tester.tap(find.byType(AccountButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cerrar sesión'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      expect(repository.logoutCalls, 0);
    });

    testWidgets('confirmar cierra la sesión', (tester) async {
      final repository = _FakeAuthRepository(alreadyAuthenticated: true);
      await pump(tester, repository);

      await tester.tap(find.byType(AccountButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cerrar sesión'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Cerrar sesión'));
      await tester.pumpAndSettle();

      expect(repository.logoutCalls, 1);
    });

    testWidgets('la confirmación aclara que los datos no se pierden',
        (tester) async {
      await pump(tester, _FakeAuthRepository(alreadyAuthenticated: true));

      await tester.tap(find.byType(AccountButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cerrar sesión'));
      await tester.pumpAndSettle();

      expect(find.textContaining('quedan guardadas en tu cuenta'), findsOneWidget);
    });
  });
}
