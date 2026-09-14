"""Client configuration, resolved from the environment and validated eagerly.

Every value here is non-secret. There is no API key setting because the
architecture has no API key: if you find yourself wanting to add one, the
design has gone wrong.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from urllib.parse import urlparse

_GUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

# 48 KiB, matching the gateway's aggregate input bound. Checking locally gives
# a clearer error than a 400 from the gateway.
MAX_INPUT_BYTES = 49152


class ConfigError(ValueError):
    """Configuration is missing or unusable."""


@dataclass(frozen=True)
class ClientConfig:
    """Resolved client configuration.

    Attributes:
        endpoint: Full gateway Responses endpoint.
        model: The single approved deployment name.
        tenant_id: Tenant the credential is pinned to.
        scope: OAuth scope requested for the Foundry audience.
        timeout_seconds: Client-side request timeout.
    """

    endpoint: str
    model: str
    tenant_id: str
    scope: str
    timeout_seconds: float = 180.0

    @property
    def base_url(self) -> str:
        """Base URL for the OpenAI SDK.

        The SDK appends ``/responses``, so strip it from the configured
        endpoint to avoid ``/responses/responses``.
        """
        return self.endpoint.removesuffix("/responses").rstrip("/")

    @classmethod
    def from_env(cls) -> ClientConfig:
        """Build configuration from environment variables.

        Raises:
            ConfigError: if anything required is missing or malformed.
        """
        endpoint = os.environ.get("MAP_ENDPOINT", "").strip()
        model = os.environ.get("MAP_MODEL", "").strip()
        tenant_id = os.environ.get("MAP_TENANT_ID", "").strip()
        scope = os.environ.get("MAP_SCOPE", "https://ai.azure.com/.default").strip()

        missing = [
            name
            for name, value in (
                ("MAP_ENDPOINT", endpoint),
                ("MAP_MODEL", model),
                ("MAP_TENANT_ID", tenant_id),
            )
            if not value
        ]
        if missing:
            raise ConfigError(
                f"Missing required environment variable(s): {', '.join(missing)}. "
                "Run scripts/postprovision.ps1 after deploying to see the correct values."
            )

        parsed = urlparse(endpoint)

        # HTTPS only. A bearer token must never traverse cleartext, and the
        # endpoint is caller-configurable, so this is checked rather than
        # assumed.
        if parsed.scheme != "https":
            raise ConfigError(
                f"MAP_ENDPOINT must use https, got '{parsed.scheme or 'no scheme'}'. "
                "Refusing to send a bearer token over an untrusted transport."
            )

        if not parsed.netloc:
            raise ConfigError(f"MAP_ENDPOINT is not a valid URL: {endpoint!r}")

        if not _GUID.match(tenant_id):
            raise ConfigError(
                f"MAP_TENANT_ID must be a tenant GUID, got {tenant_id!r}. "
                "'common' and 'organizations' are not valid: this is a single-tenant pattern."
            )

        timeout_raw = os.environ.get("MAP_TIMEOUT_SECONDS", "180")
        try:
            timeout = float(timeout_raw)
        except ValueError as exc:
            raise ConfigError(f"MAP_TIMEOUT_SECONDS must be numeric, got {timeout_raw!r}") from exc

        if timeout <= 0:
            raise ConfigError("MAP_TIMEOUT_SECONDS must be greater than zero.")

        return cls(
            endpoint=endpoint,
            model=model,
            tenant_id=tenant_id,
            scope=scope,
            timeout_seconds=timeout,
        )
