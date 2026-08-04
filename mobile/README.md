# Financiero — cliente Flutter

Cliente iOS/Android/Web de Financiero: dashboard con heatmap en vivo, chat conversacional con
el agente, ficha de inteligencia profunda por activo (con chart estilo TradingView) y
watchlist con centro de notificaciones nativas.

> **Verificado corriendo de punta a punta** (Flutter 3.44.8 estable, build web): `flutter
> analyze` limpio, y la app se corrió contra el backend real — registro/login, alta/edición/
> borrado de watchlist, heatmap, chat y centro de notificaciones, todos probados con
> screenshots reales. `android/`/`ios/` no se generaron en esta sesión (solo se necesitaba
> `web` para probar) — correr `flutter create --platforms=android,ios .` para agregarlos.

## Setup inicial

Este directorio ya tiene `pubspec.yaml`, `lib/`, `web/` y las fuentes bundleadas en
`assets/fonts/`. Si necesitás además los proyectos nativos de Android/iOS:

```bash
cd mobile
flutter create --platforms=android,ios --org com.financiero --project-name financiero_app .
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
   - Arriba del Dashboard, la card de **Resumen del día** (`GET /api/v1/market/summary`): subas y
     bajas de la jornada más el resumen ejecutivo del agente. Si falta `GEMINI_API_KEY`, la card
     muestra igual los movers con un aviso explicando qué falta — no se esconde.
   - En Chat, el chip de la cabecera dice sobre qué activo estás conversando. Se hereda de la
     selección (tocar un activo en la Watchlist o en el heatmap), se puede cambiar tocándolo, y
     la X lo desvincula para preguntar sobre el mercado en general. Con ticker el backend inyecta
     cotización en vivo + bolsa + último análisis; sin ticker, las alzas y bajas del día.

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
    dashboard/        # Pantalla 1: heatmap en vivo (MarketDataRepository) +
                      #   card de Resumen del día (MarketSummaryRepository -> GET /market/summary)
    chat/            # Pantalla 2: chat multiticker (ChatRepository -> POST /chat),
                      #   con chatTickerProvider para el activo vinculado
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

Todos los endpoints que bloqueaban las pantallas existen y el cliente está conectado a ellos:
`GET /assets/{ticker}`, `GET /alerts`, `POST /chat`, `PATCH /watchlist/{id}`,
`GET /market/quotes`, `GET /tickers` y `GET /market/summary`.

Lo que sigue faltando del lado del backend:

| Pantalla | Falta | Detalle |
|---|---|---|
| Ficha de activo (chart) | Velas históricas OHLC reales | El chart usa datos de ejemplo, marcados en la UI (`GET /api/v1/assets/{ticker}` no incluye histórico de precios, solo el análisis) |
| Ficha de activo (chart, web/desktop) | Un chart que no dependa de `webview_flutter` | `webview_flutter` solo soporta android/ios/macos; en Web, Linux y Windows la ficha muestra un placeholder temado en vez del gráfico |

### Preferencia de bolsa (NASDAQ / NYSE)

Cerrado de punta a punta. El cliente elige y persiste la bolsa (`ExchangeType` en
`features/settings/data/`, SharedPreferences vía `core/storage/preferences_storage.dart`,
`selectedExchangeProvider` + `exchangeControllerProvider`), con onboarding la primera vez
(`ExchangeOnboardingDialog`, disparado desde `AppShell`) y selector en el AppBar
(`ExchangeSelector`).

Del lado del backend existe el catálogo `Ticker` (sincronizado desde
`/v3/reference/tickers` de Polygon, normalizando el código MIC `XNAS`/`XNYS` a la bolsa del
producto), y `WatchlistItem.exchange` se enriquece solo al dar de alta un activo. La bolsa
elegida viaja como `?exchange=` a `GET /api/v1/watchlist` y `GET /api/v1/tickers`, así que la
Watchlist, el heatmap y el buscador del diálogo de alta quedan filtrados.

Dos semánticas que vale tener presentes al leer la UI:
- Las **criptos siempre se ven** con un filtro de bolsa activo: no cotizan en una bolsa de
  acciones, así que esconderlas sería perder un dato del usuario. Una acción con `exchange`
  nulo (todavía no sincronizada en el catálogo) **sí** se esconde: ahí la bolsa existe y no se
  conoce.
- La Watchlist avisa cuántos activos quedaron ocultos por el filtro, para que una lista vacía
  no parezca que se borraron los datos.

## Notas de la corrida de verificación (build web)

Corriendo la app real (`flutter build web` + servida localmente, contra el backend con
`uvicorn`) aparecieron 2 bugs reales que no se veían por análisis estático — quedaron
arreglados en `app/` y `mobile/lib/`:

- **Faltaba CORS en el backend**: sin `CORSMiddleware`, el navegador bloquea el preflight
  `OPTIONS` antes de que la request real (`POST /auth/register`, etc.) llegue a salir — 405
  Method Not Allowed, la app nunca se entera de la causa real. Fix: `app/core/config.py`
  (`cors_allowed_origins`) + `app/main.py` (`CORSMiddleware`).
- **`PushService.requestPermissionAndRegister()` sin try/catch** en el login: si Firebase no
  está configurado (o su SDK no carga), tiraba una excepción sin capturar que se veía en la
  consola del navegador. Fix en `login_screen.dart`.

También, específico de Web: por default Flutter Web baja el motor CanvasKit y la tipografía
Roboto desde CDNs de Google en el primer frame. Si esas redes están bloqueadas (firewall
corporativo, red restringida), la app queda con pantalla en blanco o texto invisible sin
ningún error visible. Dos fixes permanentes en el repo:
- `assets/fonts/` bundlea Liberation Sans (SIL OFL, métricamente compatible con Arial) como
  fuente base de la app (`AppTheme`) — nunca depende de Google Fonts.
- `web/index.html` define `window.flutterConfiguration.canvasKitBaseUrl` para preferir el
  CanvasKit local que ya viene en `build/web/canvaskit/`.

Si tu red bloquea `gstatic.com` y ves que la app sigue intentando bajar CanvasKit del CDN a
pesar de eso, el fix que efectivamente lo evita es pasar `config: { canvasKitBaseUrl:
"canvaskit/" }` al `_flutter.loader.load(...)` de `build/web/flutter_bootstrap.js` (se
regenera en cada build, así que hay que volver a aplicarlo) — no fue necesario commitear esto
porque en una red sin esa restricción `flutter build web` funciona sin tocar nada.
