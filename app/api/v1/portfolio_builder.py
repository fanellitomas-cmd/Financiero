"""`/api/v1/portfolio-builder/*` — el Constructor de Portafolios.

Un único endpoint de solo lectura: recibe un presupuesto y una lista de posiciones, y devuelve cómo
quedaría repartido. No guarda nada — la cartera simulada vive en la pantalla del cliente, y
persistirla sería otra feature con otras preguntas (¿es una cartera real?, ¿desde cuándo?, ¿con qué
precio de compra?).

**Es `POST` y no `GET` aunque no escriba nada**: el cuerpo lleva una lista de objetos anidados con
tipo de asignación y precio esperado por posición, que en query params quedaría como un puñado de
listas paralelas imposibles de validar como unidad.

**No devuelve 503 por falta de credenciales.** Con `custom_price` en cada posición la simulación se
calcula entera sin proveedor de precios, y ese es el caso de uso central de la feature: exigir
credenciales para atenderlo dejaría inalcanzable justamente lo que la distingue de la Auditoría.
"""

from __future__ import annotations

from fastapi import APIRouter

from app.api.deps import CurrentUser, PortfolioBuilderServiceDep
from app.schemas.portfolio_builder import (
    PortfolioSimulationRequest,
    PortfolioSimulationResult,
)

router = APIRouter(prefix="/portfolio-builder", tags=["portfolio-builder"])


@router.post(
    "/simulate",
    response_model=PortfolioSimulationResult,
    summary="Simula el reparto de un presupuesto entre varias posiciones",
)
async def post_simulate(
    payload: PortfolioSimulationRequest,
    current_user: CurrentUser,
    builder: PortfolioBuilderServiceDep,
) -> PortfolioSimulationResult:
    """Reparte `total_budget` entre las posiciones y devuelve unidades, montos y riesgo.

    Cada posición se expresa en unidades, en dólares o en porcentaje del presupuesto, y puede traer
    `custom_price` para simular con un precio esperado en lugar del de mercado. La respuesta trae los
    dos precios lado a lado y marca cuál se usó con `is_custom_price`.

    **Las unidades son enteras** y la fracción que no llega queda en `cash_unallocated`; el contrato
    lo declara en `unit_rounding`. Si lo pedido supera el presupuesto, no se recorta ninguna posición:
    el excedente viaja en `over_budget_amount` y el efectivo queda en 0 — elegir a cuál posición
    sacarle capital es una decisión del usuario, no del cálculo.

    **El retorno a 1 año se mide contra precios reales** incluso en las posiciones con precio
    esperado, y `return_coverage_pct` dice qué porción del capital se pudo medir: una cartera medida a
    medias no debería leerse con la misma autoridad que una medida entera.

    `risk_score` usa la misma escala y los mismos umbrales que la Auditoría de Portafolio, sobre pesos
    de capital en vez de cantidad de símbolos (`weighting_basis` lo declara).
    """

    return await builder.simulate(payload)
