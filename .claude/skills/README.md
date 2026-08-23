# Skills de seguridad (subconjunto para Financiero)

Diez skills de seguridad, elegidas del catálogo de 817 de
[mukul975/anthropic-cybersecurity-skills](https://github.com/mukul975/anthropic-cybersecurity-skills)
(Apache-2.0, autor Mahipal Jangra) por corresponder al stack real de esta app: FastAPI con sesiones
JWT, SQLAlchemy, CORS configurable, registro con código de invitación, datos por usuario (watchlist,
notas, carteras) y despliegue en Cloud Run + Firebase con CI en GitHub.

## Por qué el subconjunto y no el plugin entero

El plugin completo suma **~130 000 tokens a cada sesión** — 817 nombres+descripciones que entran en
el contexto se hable o no de seguridad. Estas diez, versionadas acá, cuestan ~1,6 k always-on y viven
con el repo: quien lo clona las tiene sin instalar nada. El resto del catálogo sigue disponible con
`claude plugin install cybersecurity-skills@…` el día que haga falta trabajo de seguridad más amplio.

## Las que están, y contra qué parte de la app

| skill | cubre |
|---|---|
| `testing-api-security-with-owasp-top-10` | paraguas OWASP API Top 10 sobre los endpoints de FastAPI |
| `testing-api-for-broken-object-level-authorization` | BOLA/IDOR: que un usuario no lea la watchlist/notas/cartera de otro |
| `testing-for-broken-access-control` | control de acceso general sobre recursos por usuario |
| `testing-jwt-token-security` | las sesiones JWT (`app/api/v1/auth.py`, almacenamiento del token en el cliente) |
| `testing-cors-misconfiguration` | el `CORS_ALLOWED_ORIGINS` que el paso 6 del deploy cierra |
| `testing-for-sensitive-data-exposure` | que datos financieros y de cuenta no se filtren en respuestas o logs |
| `implementing-secret-scanning-with-gitleaks` | los secretos del repo (clave JWT, código de invitación, keys de proveedores) |
| `securing-github-actions-workflows` | endurecer el CI |
| `integrating-sast-into-github-actions-pipeline` | SAST (semgrep) en el pipeline |
| `scanning-iac-and-images-with-trivy` | escanear el `Dockerfile`/imagen que sube a Cloud Run |

## Procedencia y verificación

- Copiadas del commit `f7626157` del repo de origen. Cada carpeta conserva su `LICENSE` (Apache-2.0).
- Cada skill trae `scripts/*.py` (código de terceros que ahora vive en este repo). Antes de commitear
  se escanearon: sin `curl|bash`, sin `exec`/`eval`, sin `os.system`, sin `pickle`, sin `shell=True`.
  Los `subprocess.run` invocan las CLIs nombradas (trivy, gitleaks, semgrep) con el comando armado
  como lista; los `b64decode` decodifican segmentos de JWT. Los hosts que aparecen son localhost,
  rangos privados y placeholders (`evil.com`, `api.target.com`). Ninguno llama a casa.
- Son herramientas de testing de seguridad: correrlas contra sistemas que no sean tuyos o sin
  autorización escrita no corresponde. Acá el objetivo es endurecer esta misma app.

Para actualizarlas, volver a copiar desde una versión más nueva del repo de origen.
