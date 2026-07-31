"""Excepciones de dominio. Ver .cursorrules §2 (Manejo de Errores): nunca propagar excepciones
crudas de httpx/SDKs de proveedores hacia la capa de procesamiento.
"""


class FinancialAgentError(Exception):
    pass


class InsufficientMarketDataError(FinancialAgentError):
    pass


class StaleDataError(FinancialAgentError):
    pass


class ProviderRateLimitError(FinancialAgentError):
    pass
