# Publicar Financiero en Google Cloud

Backend en **Cloud Run**, base en **Cloud SQL (Postgres)**, cliente web en **Firebase Hosting**.
Al final hay una URL como `https://financiero-xxxx.web.app` a la que el usuario entra, se registra
con el código de invitación y usa la app.

## Antes de empezar

```bash
gcloud --version      # SDK de Google Cloud, autenticado: gcloud auth login
firebase --version    # npm i -g firebase-tools, autenticado: firebase login
```

Hace falta un proyecto de GCP con facturación activa. Fijalo una vez:

```bash
export PROJECT=tu-proyecto
export REGION=southamerica-east1     # São Paulo; la más cercana si el uso es del Río de la Plata
gcloud config set project "$PROJECT"
gcloud services enable run.googleapis.com sqladmin.googleapis.com \
    secretmanager.googleapis.com cloudbuild.googleapis.com \
    artifactregistry.googleapis.com cloudscheduler.googleapis.com
```

### El orden importa

Hay una dependencia circular: el frontend necesita la URL del backend, y el CORS del backend
necesita el dominio del frontend. Se resuelve así, y saltearse el paso 6 deja la app cargando pero
sin poder llamar a la API:

**1** base → **2** secretos → **3** backend → **4** frontend → **5** backend con el CORS puesto.

---

## 1. Base de datos

`db-f1-micro` es el instancia más chica y alcanza para una app de pocos usuarios. Es el **único
componente que cobra estando idle** en el despliegue mínimo (~US$ 8–10 por mes); Cloud Run baja a
cero y no cobra. (Al escalar se suma Memorystore, paso 1b — opcional hasta entonces.)

```bash
gcloud sql instances create financiero-db \
    --database-version=POSTGRES_15 --tier=db-f1-micro --region="$REGION"

gcloud sql databases create financiero --instance=financiero-db

# Guardá esta contraseña: va en el secreto del paso 2.
gcloud sql users create financiero_app --instance=financiero-db --password='PONE-UNA-LARGA'
```

El nombre de conexión (`PROYECTO:REGION:INSTANCIA`) se usa en el paso 3:

```bash
export SQL_CONN=$(gcloud sql instances describe financiero-db \
    --format='value(connectionName)')
```

## 1b. (opcional hasta escalar) Redis — límite de intentos de login

El backend limita los intentos de login para frenar la fuerza bruta, y el contador puede vivir en dos
lados:

- **Lanzamiento a costo cero (recomendado para empezar):** el contador en memoria del proceso. **No
  cuesta nada** y funciona bien con **una sola instancia** — ahí el conteo por proceso es el conteo
  global. Se activa corriendo Cloud Run con `--max-instances=1` y poniendo
  `LOGIN_RATE_LIMIT_ALLOW_IN_MEMORY=true` (paso 3). No hace falta nada de esta sección.
- **Al escalar:** cuando subas `--max-instances` por encima de 1, cada instancia contaría por su lado
  y el límite se afloja. Ahí el contador tiene que ser compartido → Redis (Memorystore). Es el
  segundo componente que cobra estando idle (~US$ 25–35 por mes el tier más chico), así que tiene
  sentido recién cuando el tráfico lo justifica.

Cuando llegue ese momento, creá Memorystore y el conector de VPC (Cloud Run alcanza la IP privada de
Redis sólo a través de él):

```bash
gcloud services enable redis.googleapis.com vpcaccess.googleapis.com

gcloud redis instances create financiero-cache \
    --region "$REGION" --tier=basic --size=1 --redis-version=redis_7_0

export REDIS_HOST=$(gcloud redis instances describe financiero-cache \
    --region "$REGION" --format='value(host)')

gcloud compute networks vpc-access connectors create financiero-conn \
    --region "$REGION" --range 10.8.0.0/28
```

> **Por qué no Cloud Armor para esto.** Cloud Armor es rate-limiting por IP en el borde (anti-DDoS),
> y no reemplaza el límite por cuenta: un ataque distribuido contra un solo email desde muchas IP se
> le escapa. Además no es gratis — necesita un balanceador de carga externo adelante (que cobra por
> hora estés o no usándolo) más el cargo por política. Sirve como capa extra a gran escala, no como
> la protección de login ni como la opción barata.

## 2. Secretos

Nunca en variables de entorno del servicio ni en el repo: en Secret Manager, que Cloud Run monta.

```bash
# El JWT firma las sesiones. Con el placeholder del repo, cualquiera que lo lea puede firmar un
# token válido para cualquier cuenta — el arranque en `production` se niega justamente por esto.
python -c "import secrets; print(secrets.token_urlsafe(48))" | \
    gcloud secrets create jwt-secret-key --data-file=-

python -c "import secrets; print(secrets.token_urlsafe(48))" | \
    gcloud secrets create internal-api-key --data-file=-

# El código que vas a compartir con quien quieras que entre.
printf 'el-codigo-que-elijas' | \
    gcloud secrets create registration-invite-code --data-file=-

# La URL de la base, con la contraseña del paso 1. `host=/cloudsql/...` es el socket unix que
# Cloud Run expone cuando se le pasa --add-cloudsql-instances.
printf 'postgresql+asyncpg://financiero_app:PONE-UNA-LARGA@/financiero?host=/cloudsql/%s' "$SQL_CONN" | \
    gcloud secrets create database-url --data-file=-

# SÓLO al escalar (paso 1b): la URL de Redis/Memorystore. En el lanzamiento a costo cero se saltea —
# no hay instancia de Redis todavía. No es un secreto en sentido estricto —es una IP privada— pero se
# monta igual que los demás para no dispersar la config del servicio.
#   printf 'redis://%s:6379' "$REDIS_HOST" | gcloud secrets create redis-url --data-file=-

# Las de los proveedores. Sin estas la app entra y funciona, pero degradada: cada pantalla que
# depende de un proveedor muestra su aviso en vez de datos.
printf 'tu-key' | gcloud secrets create polygon-api-key --data-file=-
printf 'tu-key' | gcloud secrets create fmp-api-key --data-file=-
printf 'tu-key' | gcloud secrets create tavily-api-key --data-file=-
printf 'tu-key' | gcloud secrets create gemini-api-key --data-file=-
```

Dale acceso a la cuenta de servicio de Cloud Run:

```bash
export SA="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')-compute@developer.gserviceaccount.com"
# Al escalar, agregá `redis-url` a esta lista.
for s in jwt-secret-key internal-api-key registration-invite-code database-url \
         polygon-api-key fmp-api-key tavily-api-key gemini-api-key; do
  gcloud secrets add-iam-policy-binding "$s" \
      --member="serviceAccount:$SA" --role=roles/secretmanager.secretAccessor
done
```

## 3. Backend

`--allow-unauthenticated` es correcto acá: la autenticación es de la aplicación (JWT), no de IAM.
Lo que queda público es el endpoint de login, igual que en cualquier API con usuarios.

Lanzamiento a costo cero: **una sola instancia** (`--max-instances=1`) y el límite de login en
memoria (`LOGIN_RATE_LIMIT_ALLOW_IN_MEMORY=true`). Con una instancia el conteo por proceso es global,
así que el login queda igual de protegido y no se paga Redis.

```bash
gcloud run deploy financiero-api \
    --source . \
    --region "$REGION" \
    --allow-unauthenticated \
    --max-instances 1 \
    --add-cloudsql-instances "$SQL_CONN" \
    --set-env-vars 'ENVIRONMENT=production,SCHEDULER_ENABLED=false,LOGIN_RATE_LIMIT_ALLOW_IN_MEMORY=true,CORS_ALLOWED_ORIGINS=["https://PLACEHOLDER"]' \
    --set-secrets 'DATABASE_URL=database-url:latest,JWT_SECRET_KEY=jwt-secret-key:latest,INTERNAL_API_KEY=internal-api-key:latest,REGISTRATION_INVITE_CODE=registration-invite-code:latest,POLYGON_API_KEY=polygon-api-key:latest,FMP_API_KEY=fmp-api-key:latest,TAVILY_API_KEY=tavily-api-key:latest,GEMINI_API_KEY=gemini-api-key:latest'
```

> **Al escalar (más de una instancia):** montá Memorystore (paso 1b) y cambiá el deploy — sacá
> `--max-instances 1` y `LOGIN_RATE_LIMIT_ALLOW_IN_MEMORY=true`, agregá `--vpc-connector financiero-conn`
> y `REDIS_URL=redis-url:latest` a `--set-secrets`. Ojo: **es tu responsabilidad acordarte**. La app no
> ve el `--max-instances`, así que mientras el flag esté en `true` arranca igual sin quejarse; si subís
> las instancias y te olvidás de sacarlo, el límite de login se afloja en silencio (cada instancia
> cuenta por su lado). Sacá el flag y ahí sí, sin `REDIS_URL`, el arranque en `production` se niega.

**`SCHEDULER_ENABLED=false` no es opcional.** El scheduler interno de APScheduler asume un proceso
que vive; Cloud Run apaga el contenedor cuando no hay tráfico y levanta varios cuando hay, así que
correría de a ratos y en paralelo consigo mismo. El paso 7 lo reemplaza por Cloud Scheduler.

El `Dockerfile` corre `alembic upgrade head` al arrancar. Si el despliegue falla acá, es la base:
revisá la URL del secreto y que `--add-cloudsql-instances` esté puesto.

Anotá la URL:

```bash
export API_URL=$(gcloud run services describe financiero-api \
    --region "$REGION" --format='value(status.url)')
echo "$API_URL"
```

## 4. Cliente web

`API_BASE_URL` se compila DENTRO del bundle, así que este build es específico de este backend:
cambiar de URL obliga a rebuildear.

```bash
cd mobile
flutter build web --release --dart-define=API_BASE_URL="$API_URL/api/v1"
cd ..
```

> `mobile/web/flutter_bootstrap.js` hace que CanvasKit se sirva desde tu dominio en vez de
> `gstatic.com`. No lo saques: en una red donde ese CDN esté bloqueado, la app carga el HTML y
> después queda en blanco sin decir por qué.

## 5. Frontend

```bash
firebase use --add "$PROJECT"     # crea .firebaserc (está en .gitignore: es tuyo, no del repo)
firebase deploy --only hosting
```

La URL que imprime (`https://PROJECT.web.app`) es **el link que compartís**.

## 6. Cerrar el CORS

Con `["*"]` cualquier sitio puede llamar a tu API desde el navegador de un usuario logueado. Ahora
que existe el dominio, ponelo:

```bash
gcloud run services update financiero-api --region "$REGION" \
    --update-env-vars "CORS_ALLOWED_ORIGINS=[\"https://$PROJECT.web.app\",\"https://$PROJECT.firebaseapp.com\"]"
```

Los dos dominios: Firebase Hosting sirve en ambos y el navegador manda el `Origin` real.

## 7. El agente periódico

Reemplaza al scheduler que se apagó en el paso 3. El endpoint ya existe y está protegido con
`INTERNAL_API_KEY`:

```bash
gcloud scheduler jobs create http financiero-agente \
    --location "$REGION" \
    --schedule '*/15 9-17 * * 1-5' \
    --time-zone 'America/Argentina/Buenos_Aires' \
    --uri "$API_URL/api/v1/internal/trigger-agent" \
    --http-method POST \
    --headers "X-Internal-API-Key=$(gcloud secrets versions access latest --secret=internal-api-key)" \
    --message-body '{}'
```

## 8. Catálogo de símbolos

El buscador de activos lee la tabla `tickers`, que arranca vacía. Sin esto, no se puede agregar nada
a la watchlist ni al Constructor de Portafolios:

```bash
# Con el proxy de Cloud SQL corriendo local y DATABASE_URL apuntando a la instancia:
python -m scripts.sync_tickers
```

## Cómo entra el usuario

1. Abre `https://PROJECT.web.app`.
2. Cae en `/auth` → pestaña **Crear cuenta**.
3. Email, contraseña (mínimo 8, validado en el cliente) y el **código de invitación** del paso 2. Sin
   el código, el backend responde 403 y la pantalla muestra **su** mensaje, no una suposición.
   La casilla "Recordar mi sesión" viene tildada; destildada, el token vive solo en memoria y al
   cerrar la pestaña hay que entrar de nuevo.
4. Adentro: Dashboard, Chat, Watchlist, Corporativo y Lab en la barra. El Laboratorio Financiero
   está en `/ai-lab` y el Constructor en `/portfolio-builder`; a los dos se llega desde la ficha de
   un activo.

Para cerrar sesión: menú de cuenta en la barra del Dashboard, o al pie del rail en escritorio.

Para dar de baja a alguien, hoy hay que borrar la fila de `users` a mano. Rotar el código de
invitación **no** saca a quien ya entró.

## Qué esto no incluye

- **Dominio propio.** `firebase hosting:sites` y un CNAME; después hay que agregarlo al CORS.
- **Backups de la base.** `gcloud sql instances patch --backup-start-time` los activa.
- **Despliegue automático.** Los pasos 3–5 son manuales a propósito: un `git push` que despliega
  necesita Workload Identity Federation y una cuenta de servicio, y es más superficie de la que
  justifica una app de pocos usuarios.
- **Observabilidad más allá de Cloud Logging.** Los logs estructurados ya salen; no hay alertas.
