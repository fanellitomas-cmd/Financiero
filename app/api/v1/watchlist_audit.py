"""`GET/POST /api/v1/watchlist/audit` — Auditoría de Portafolio por IA sobre la Watchlist del
usuario autenticado.

Router propio y no una ruta más en `app/api/v1/watchlist.py` por dos motivos: el ABM de la
watchlist y la auditoría no comparten nada más que el prefijo, y las rutas literales tienen que
declararse antes que `PATCH /watchlist/{item_id}` para que `/audit` no se lea como un UUID de item
(ver el orden de `include_router` en `app/api/v1/router.py`).
"""

from __future__ import annotations

from fastapi import APIRouter, status

from app.api.deps import CurrentUser, PortfolioAuditDep
from app.schemas.portfolio_audit import PortfolioAudit

router = APIRouter(prefix="/watchlist", tags=["watchlist"])

_DESCRIPTION = """Distribución por sector, concentración de riesgo, advertencias de correlación,
sugerencias de diversificación y una narrativa redactada por IA sobre los cuatro.

Los porcentajes son **equiponderados por cantidad de activos**: la watchlist no guarda cantidades
ni precio de compra, así que "40% en Tecnología" significa 4 de cada 10 activos seguidos, no 40
centavos de cada peso invertido. Viaja explícito en `weighting_basis`.

Siempre 200 con estructura válida: una watchlist vacía, un catálogo sin sectores o un entorno sin
credenciales de IA devuelven la auditoría con los bloques que se pudieron armar más
`availability` y `degradation_reason`."""


@router.get(
    "/audit",
    response_model=PortfolioAudit,
    summary="Auditoría de portafolio (respeta la caché)",
    description=_DESCRIPTION,
)
async def get_portfolio_audit(
    # `current_user` antes que el servicio: FastAPI resuelve en orden de firma, y así un pedido sin
    # token corta con 401 sin revelar el estado de configuración del backend.
    current_user: CurrentUser,
    audit_service: PortfolioAuditDep,
) -> PortfolioAudit:
    return await audit_service.get_audit(current_user.id)


@router.post(
    "/audit",
    response_model=PortfolioAudit,
    status_code=status.HTTP_200_OK,
    summary="Recalcular la auditoría de portafolio",
    description=(
        "Misma respuesta que el GET, ignorando la caché. Es la operación cara (una llamada al "
        "modelo más una al proveedor de fundamentales por símbolo nuevo y una al de precios por "
        "símbolo): el uso normal debe ser el GET.\n\n"
        "200 y no 201: no se crea ningún recurso, se recalcula uno que ya existía. El verbo es "
        "POST porque la operación no es idempotente en costo — dispara trabajo y gasto real contra "
        "proveedores externos — y un GET no debería hacer eso."
    ),
)
async def refresh_portfolio_audit(
    current_user: CurrentUser,
    audit_service: PortfolioAuditDep,
) -> PortfolioAudit:
    return await audit_service.get_audit(current_user.id, force_refresh=True)
