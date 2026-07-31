# Financiero — cliente Flutter

Cliente iOS/Android/Web de Financiero: dashboard, chat con el agente, ficha de inteligencia
profunda por activo (con chart estilo TradingView) y watchlist con notificaciones push.

> **Nota sobre este código**: se escribió en un entorno remoto sin el SDK de Flutter instalado,
> así que nunca se corrió `flutter pub get` / `flutter analyze` / `flutter test` acá — no hay
> forma de verificarlo en esta sesión. Está escrito con cuidado contra las APIs conocidas de
> cada paquete, pero corré `flutter analyze` apenas lo bajes, antes de asumir que compila.

## Setup inicial

Este directorio ya tiene `pubspec.yaml` y todo `lib/` — le faltan los proyectos nativos
(`android/`, `ios/`, `web/`, etc.), que `flutter create` genera sin tocar `lib/`/`pubspec.yaml`
si ya existen:

```bash
cd mobile
flutter create --org com.financiero --project-name financiero_app .
flutter pub get
```

Después:

1. **Firebase (push)**: correr `flutterfire configure` (requiere el proyecto de Firebase ya
   creado en la consola) — genera `lib/firebase_options.dart` y deja `google-services.json` /
   `GoogleService-Info.plist` en su lugar. Sin esto, `Firebase.initializeApp()` en `main.dart`
   falla silenciosamente (se loguea, no crashea) y el resto de la app funciona igual, sin push.
2. **Backend**: levantar la API (`uvicorn app.main:app --reload` desde la raíz del repo) y
   correr la app apuntándole:
   ```bash
   flutter run \
     --dart-define=API_BASE_URL=http://10.0.2.2:8000/api/v1 \
     --dart-define=WS_BASE_URL=ws://10.0.2.2:8000/api/v1
   ```
   (`10.0.2.2` es el alias del emulador de Android hacia el `localhost` del host; en iOS
   Simulator o Web usar `localhost` directo; en un dispositivo físico, la IP de la red local.)

## Arquitectura

```
lib/
  core/
    config/        # AppConfig (URLs vía --dart-define)
    storage/        # TokenStorage (JWT en secure storage)
    network/        # ApiClient (Dio + interceptor JWT/401), TickerSocketService (WS)
    push/            # PushService (registro de token FCM contra /api/v1/devices)
    router/          # go_router + redirect basado en AuthState
    theme/           # tema único (dark-first)
    widgets/         # AppShell (bottom nav)
    providers.dart    # todos los providers de infraestructura, un único lugar
  features/
    auth/            # login/registro, AuthController (sesión)
    dashboard/        # Pantalla 1: heatmap de la watchlist + daily digest
    chat/            # Pantalla 2: chat conversacional (UI lista, falta el endpoint)
    asset_detail/    # Pantalla 3: ficha de inteligencia profunda + chart (WebView)
    watchlist/        # Pantalla 4: CRUD de watchlist
```

Cada `feature/` separa `data/` (repositorios + modelos que espejan los schemas Pydantic del
backend) de `presentation/` (pantallas + estado). Los modelos se hand-codean (sin
`json_serializable`/build_runner): son pocos campos y así no hay paso de codegen para compilar.

## Gaps conocidos del backend (bloquean completar algunas pantallas)

Estos NO son bugs del cliente — son endpoints que todavía no existen en `app/api/v1/` y que
cada pantalla necesita para dejar de mostrar placeholders:

| Pantalla | Falta | Detalle |
|---|---|---|
| Dashboard (heatmap) | `GET` de precio/%var en vivo por ticker | Hoy no hay lectura de mercado fuera del pipeline interno |
| Dashboard (daily digest) | Un resumen generado por el agente, expuesto por API | No existe ese concepto en el backend todavía |
| Chat | Endpoint conversacional (`POST /api/v1/chat` o similar) | `ChatRepository.send` tira `UnimplementedError` a propósito |
| Ficha de activo | `GET /api/v1/assets/{ticker}` on-demand | Hoy la Ficha solo recibe datos cuando el motor despacha una alerta nueva por WS |
| Ficha de activo (chart) | Velas históricas OHLC | El chart usa datos de ejemplo, marcados en la UI |
| Watchlist (notificaciones) | `GET /api/v1/alerts` sobre `AlertHistory` | La tabla existe (`app/models/alert_history.py`) pero no se expone al usuario todavía |
| Watchlist (editar) | `PATCH /api/v1/watchlist/{id}` | Hoy solo se puede crear/borrar, no editar el umbral o el modo principiante después de creado |

Ninguno bloquea correr la app — son placeholders explícitos, no funcionalidad rota.
