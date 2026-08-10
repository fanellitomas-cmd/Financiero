"""`/api/v1/ai-lab/*` — el Laboratorio Financiero y el Simulador de Escenarios.

Dos endpoints de solo lectura sobre los estados contables de una empresa. Ninguno guarda nada: el
diagnóstico es un cálculo sobre datos del proveedor y el hilo de la conversación lo administra el
cliente, que lo manda entero en cada request.

**Son `POST` y no `GET` aunque no escriban nada**, por dos razones concretas: el cuerpo del
diagnóstico lleva un historial de conversación que no cabe razonablemente en un query string, y el
simulador recibe un objeto de variables anidado que en query params quedaría como una lista de
parámetros planos imposible de validar como unidad.

**Ninguno devuelve 503 por falta de credenciales.** Los dos responden 200 con su estructura válida,
`availability=UNAVAILABLE` y un motivo legible. Un 503 obligaría al cliente a traducir "no
configurado" a un aviso, que es exactamente lo que la respuesta ya trae.
"""

from __future__ import annotations

from fastapi import APIRouter

from app.api.deps import AiLabServiceDep, CurrentUser
from app.schemas.ai_lab import (
    FinancialAnalysisRequest,
    FinancialAnalysisResponse,
    ScenarioSimulationRequest,
    ScenarioSimulationResult,
)

router = APIRouter(prefix="/ai-lab", tags=["ai-lab"])


@router.post(
    "/financial-analysis",
    response_model=FinancialAnalysisResponse,
    summary="Diagnóstico contable de un símbolo, conversacional",
)
async def post_financial_analysis(
    payload: FinancialAnalysisRequest,
    current_user: CurrentUser,
    ai_lab: AiLabServiceDep,
) -> FinancialAnalysisResponse:
    """Balance, resultados, DuPont, flujo de caja y banderas, más la lectura escrita.

    **Todos los números salen de fórmulas en código**, con umbrales explícitos que viajan dentro de
    cada bandera. El modelo interviene solo para redactar la lectura, y la respuesta lo declara en
    `narrative_source`: sin esa distinción, un párrafo bien escrito y una cifra calculada se
    presentarían con la misma autoridad.

    Sin `question` devuelve el diagnóstico general. Con `question` responde eso en particular sobre
    los mismos datos, y `history` mantiene el hilo — el cliente es dueño de la conversación y la
    manda entera en cada turno.
    """

    return await ai_lab.analyze(payload)


@router.post(
    "/simulate",
    response_model=ScenarioSimulationResult,
    summary="Simulación de escenarios What-If sobre un símbolo",
)
async def post_simulate(
    payload: ScenarioSimulationRequest,
    current_user: CurrentUser,
    ai_lab: AiLabServiceDep,
) -> ScenarioSimulationResult:
    """Proyecta ingresos, EBITDA, EPS y FCF a partir de las variables del escenario.

    La cascada es determinística y sus supuestos viajan en `model_assumptions`: qué se mantuvo
    constante, con qué tasa se gravó y de dónde sale el múltiplo. Una proyección sin sus supuestos
    tiene la autoridad de un pronóstico y la solidez de una cuenta al margen.

    El precio implícito mantiene el múltiplo actual y mueve el EPS — `valuation_basis` lo dice, y
    cuando el EPS base no lo permite viaja en `null` con su motivo en vez de un 0.

    El evento en texto (`custom_event`) **no entra en ninguna fórmula**: se lo explica al usuario y la
    respuesta lo marca con `custom_event_is_qualitative`. Cuantificar un rumor sería pedirle al modelo
    un coeficiente que nadie midió.
    """

    return await ai_lab.simulate(payload)
