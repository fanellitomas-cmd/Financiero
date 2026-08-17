# Imagen del backend para Cloud Run.
#
# `python:3.11-slim` y no `alpine`: `asyncpg` y `bcrypt` traen ruedas compiladas para glibc, y en
# alpine (musl) habría que compilarlas, lo que multiplica el tiempo de build sin ganar nada.
FROM python:3.11-slim

# `PYTHONUNBUFFERED` es lo que hace que los logs aparezcan en Cloud Logging al momento y no cuando
# el buffer se llena — sin esto, un arranque que falla no deja rastro.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Las dependencias van en su propia capa, antes del código: Docker la reusa mientras
# `requirements.txt` no cambie, y un cambio de una línea de Python no reinstala todo.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY src ./src
COPY prompts ./prompts
COPY alembic ./alembic
COPY alembic.ini ./
COPY scripts ./scripts

# Cloud Run inyecta `PORT` y espera que el proceso escuche ahí. El default es para correr la imagen
# local con `docker run -p 8000:8000`.
ENV PORT=8000

# Las migraciones corren en el arranque del contenedor. Es lo simple y alcanza para una instancia;
# con varias en paralelo, dos arranques simultáneos pueden pelearse por la tabla de versiones de
# Alembic. Para eso, sacá el `alembic upgrade` de acá y corrélo como un Cloud Run Job antes de
# desplegar la revisión nueva.
CMD alembic upgrade head && \
    exec uvicorn app.main:app --host 0.0.0.0 --port "${PORT}" --proxy-headers
