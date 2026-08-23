#!/usr/bin/env bash
# Deja el grafo de conocimiento actualizándose solo: instala los hooks de git que lo reconstruyen
# después de cada commit y de cada cambio de rama, y arma el grafo si todavía no existe.
#
# Por qué hace falta un script y no alcanza con correrlo una vez: los hooks viven en `.git/hooks/`,
# que git NO versiona. En un clon nuevo, en la máquina de otro, o en un contenedor efímero de CI o
# de un asistente, `.git/hooks/` arranca vacío y el grafo se queda viejo sin avisar — que es la peor
# forma de fallar acá, porque el grafo sigue respondiendo consultas, solo que sobre el código de
# antes. Esto es lo único que hay que correr para reponerlo.
#
# Uso:
#     bash scripts/setup_graphify.sh
#
# Es idempotente: correrlo de nuevo reinstala los hooks y deja el grafo como está si ya está al día.
#
# Para saltear la reconstrucción en un commit puntual (por ejemplo, uno que solo toca documentación):
#     GRAPHIFY_SKIP_HOOK=1 git commit -m "..."

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v graphify >/dev/null 2>&1; then
    cat >&2 <<'FALTA'
graphify no está en el PATH. Instalalo y volvé a correr este script:

    uv tool install "graphifyy[mcp]"

El extra [mcp] no es opcional: sin él `graphify-mcp` arranca y muere con
ModuleNotFoundError: No module named 'mcp', y el servidor que declara .mcp.json no levanta.
FALTA
    exit 1
fi

echo "graphify: $(graphify --version)"

# Instala post-commit y post-checkout. La reconstrucción que disparan corre desasociada del shell,
# así que `git commit` vuelve enseguida y el grafo queda listo unos segundos después (para este repo,
# ~20 s). El log va a ~/.cache/graphify-rebuild.log.
graphify hook install

# El grafo en sí no viaja en el repo (ver el motivo en .gitignore), así que en un clon nuevo hay que
# construirlo una vez. A partir de ahí lo mantienen los hooks.
if [ -f graphify-out/graph.json ]; then
    echo "grafo ya construido en graphify-out/ (los hooks lo mantienen al día)"
else
    echo "no hay grafo todavía: construyéndolo (extracción local por AST, sin API keys)..."
    graphify update .
fi

echo
graphify hook status
