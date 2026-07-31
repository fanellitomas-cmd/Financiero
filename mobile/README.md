# Financiero — cliente Flutter

Cliente iOS/Android/Web de Financiero: dashboard con heatmap en vivo, chat conversacional con
el agente, ficha de inteligencia profunda por activo (con chart estilo TradingView) y
watchlist con centro de notificaciones nativas.

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
2. **Backend**: levantar la API (`uvicorn app.main:app --reload` desde la raíz del repo, con
   `POLYGON_API_KEY`/`FMP_API_KEY`/`TAVILY_API_KEY`/`GEMINI_API_KEY` en `.env` si querés la
   Ficha on-demand, el chat y el heatmap con datos reales — sin esas keys esos tres endpoints
   responden 503 explícito, no rompen la app) y correr la app apuntándole:
   ```bash
   flutter run \
     --dart-define=API_BASE_URL=http://10.0.2.2:8000/api/v1 \
     --dart-define=WS_BASE_URL=ws://10.0.2.2:8000/api/v1
   ```
   (`10.0.2.2` es el alias del emulador de Android hacia el `localhost` del host; en iOS
   Simulator o Web usar `localhost` directo; en un dispositivo físico, la IP de la red local.)
3. **Probar el flujo completo**: registrate/logueate en la app, agregá un ticker a la
   Watchlist (botón `+`), y desde ahí:
   - Tocalo para abrir la Ficha (`GET /api/v1/assets/{ticker}` on-demand + WebSocket en vivo).
   - Usá el ícono de campana en el AppBar de Watchlist para ver el Centro de Notificaciones
     (`GET /api/v1/alerts`, paginado).
   - Probá el ícono de lápiz en un item de la Watchlist para editar umbral/modo principiante
     (`PATCH /api/v1/watchlist/{id}`).
   - En el Dashboard, el heatmap debería mostrar %var en vivo (`GET /api/v1/market/quotes`) si
     `POLYGON_API_KEY` está configurada.
   - En Chat, elegí un ticker de tu Watchlist en el dropdown y preguntale algo — la respuesta
     viene de Gemini con contexto del último `AlertHistory` de ese ticker, si existe.

## Arquitectura

```
lib/
  core/
    config/        # AppConfig (URLs vía --dart-define)
    storage/        # TokenStorage (JWT en secure storage)
    network/        # ApiClient (Dio + interceptor JWT/401), TickerSocketService (WS),
                     # api_error.dart (traduce errores de red/API a mensajes de UI)
    push/            # PushService (registro de token FCM contra /api/v1/devices)
    router/          # go_router + redirect basado en AuthState
    theme/           # tema único (dark-first)
    widgets/         # AppShell (bottom nav)
    providers.dart    # todos los providers de infraestructura, un único lugar
  features/
    auth/            # login/registro, AuthController (sesión)
    dashboard/        # Pantalla 1: heatmap en vivo (MarketDataRepository) + daily digest
    chat/            # Pantalla 2: chat conversacional (ChatRepository -> POST /chat)
    asset_detail/    # Pantalla 3: ficha on-demand (AssetRepository) + WebSocket en vivo + chart
    alerts/          # Centro de Notificaciones: AlertsRepository -> GET /alerts, paginado
    watchlist/        # Pantalla 4: CRUD completo de watchlist, incluye PATCH
```

Cada `feature/` separa `data/` (repositorios + modelos que espejan los schemas Pydantic del
backend) de `presentation/` (pantallas + estado). Los modelos se hand-codean (sin
`json_serializable`/build_runner): son pocos campos y así no hay paso de codegen para compilar.

### Cómo se combina la Ficha on-demand con el WebSocket en vivo

`AssetDetailScreen` mira dos providers a la vez: `assetIntelligenceProvider` (fetch único
contra `GET /api/v1/assets/{ticker}` al abrir la pantalla — evita depender de esperar la
próxima corrida del scheduler) y `tickerPayloadProvider` (el `WS /api/v1/ws/{ticker}` ya
existente). Si llega una alerta nueva por WS mientras la pantalla está abierta, esa tiene
prioridad sobre el resultado del fetch inicial — se refleja al toque sin que el usuario tenga
que recargar.

## Gaps conocidos del backend

La tabla de gaps que bloqueaba las 4 pantallas está **cerrada**: los 5 endpoints que faltaban
(`GET /assets/{ticker}`, `GET /alerts`, `POST /chat`, `PATCH /watchlist/{id}`,
`GET /market/quotes`) ya existen en `app/api/v1/` y el cliente está conectado a los cinco. Lo
único que sigue siendo un placeholder explícito en la UI (no un endpoint faltante, una
funcionalidad que directamente no está en el alcance actual del backend):

| Pantalla | Falta | Detalle |
|---|---|---|
| Dashboard (daily digest) | Un resumen generado por el agente, expuesto por API | No existe ese concepto en el backend todavía — la card lo dice explícitamente |
| Ficha de activo (chart) | Velas históricas OHLC reales | El chart usa datos de ejemplo, marcados en la UI (`GET /api/v1/assets/{ticker}` no incluye histórico de precios, solo el análisis) |

Ninguno bloquea correr la app — son placeholders explícitos, no funcionalidad rota.
