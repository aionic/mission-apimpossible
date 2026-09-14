"""Reference client for the Mission APIMpossible gateway.

Deliberately small. Its job is to demonstrate the identity and correlation
properties, not to be a chat application.
"""

from map_client.config import ClientConfig, ConfigError
from map_client.correlation import RequestContext
from map_client.responses import InvocationResult, ResponsesClient

__all__ = [
    "ClientConfig",
    "ConfigError",
    "InvocationResult",
    "RequestContext",
    "ResponsesClient",
]
