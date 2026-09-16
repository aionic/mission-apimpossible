"""Proxy configuration, validated eagerly.

Everything here is non-secret except the session secret, which is generated at
runtime and never read from configuration. There is deliberately no setting to
supply one: a secret that can be configured is a secret that ends up in a
dotfile, and this one has no reason to outlive the process.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from urllib.parse import urlparse

_GUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

# Loopback, IPv4, explicitly.
#
# Never 0.0.0.0 - that would expose a token-bearing listener to the network.
#
# Never the NAME "localhost" either: it can resolve to ::1 first, and if the
# IDE reaches ::1 while this binds 127.0.0.1 the connection simply fails with
# nothing useful to explain why.
BIND_HOST = "127.0.0.1"

DEFAULT_PORT = 8787


class ProxyConfigError(ValueError):
    """Configuration is missing or unusable."""


@dataclass(frozen=True)
class ModelEntry:
    """One deployment advertised to the IDE.

    Sourced from configuration rather than discovered from Foundry, so the
    proxy cannot advertise a model the gateway would reject.
    """

    deployment: str
    display_name: str
    max_input_tokens: int = 128000
    max_output_tokens: int = 4096


@dataclass(frozen=True)
class ProxyConfig:
    """Resolved proxy configuration.

    Attributes:
        gateway_endpoint: The APIM Responses endpoint requests are forwarded to.
        tenant_id: Tenant the credential is pinned to.
        scope: OAuth scope requested for the Foundry audience.
        models: Deployments advertised on ``GET /v1/models``.
        port: Loopback port to listen on.
        capture_path: When set, write redacted request/response captures here.
        timeout_seconds: Upstream request timeout.
    """

    gateway_endpoint: str
    tenant_id: str
    scope: str
    models: tuple[ModelEntry, ...] = field(default_factory=tuple)
    port: int = DEFAULT_PORT
    capture_path: str | None = None
    timeout_seconds: float = 180.0

    @property
    def base_url(self) -> str:
        """Origin the IDE should be pointed at."""
        return f"http://{BIND_HOST}:{self.port}/v1"

    @classmethod
    def from_env(
        cls,
        *,
        gateway_endpoint: str | None = None,
        tenant_id: str | None = None,
        scope: str | None = None,
        models: tuple[ModelEntry, ...] | None = None,
        port: int | None = None,
        capture_path: str | None = None,
    ) -> ProxyConfig:
        """Builds configuration from the MAP_* environment, with overrides.

        Reuses the same variables as the Python client, so a developer who has
        already run ``scripts/use-environment.ps1`` needs no extra setup.

        Raises:
            ProxyConfigError: if anything required is missing or malformed.
        """
        endpoint = (gateway_endpoint or os.environ.get("MAP_ENDPOINT", "")).strip()
        tenant = (tenant_id or os.environ.get("MAP_TENANT_ID", "")).strip()
        scope_value = (scope or os.environ.get("MAP_SCOPE", "")).strip()

        missing = [
            name
            for name, value in (
                ("MAP_ENDPOINT", endpoint),
                ("MAP_TENANT_ID", tenant),
                ("MAP_SCOPE", scope_value),
            )
            if not value
        ]
        if missing:
            raise ProxyConfigError(
                f"Missing required configuration: {', '.join(missing)}. "
                "Dot-source scripts/use-environment.ps1, or pass --endpoint and --tenant."
            )

        parsed = urlparse(endpoint)

        # The gateway is remote, so a bearer token crosses a real network to
        # reach it. Cleartext is refused here, unlike the loopback listener,
        # where plain HTTP never leaves the machine.
        if parsed.scheme != "https":
            raise ProxyConfigError(
                f"The gateway endpoint must use https, got '{parsed.scheme or 'no scheme'}'. "
                "Refusing to forward a bearer token over an untrusted transport."
            )
        if not parsed.netloc:
            raise ProxyConfigError(f"The gateway endpoint is not a valid URL: {endpoint!r}")

        if not _GUID.match(tenant):
            raise ProxyConfigError(
                f"The tenant must be a GUID, got {tenant!r}. "
                "'common' and 'organizations' are not valid: this is a single-tenant pattern."
            )

        # Models: explicit override wins, else MAP_MODELS (comma-separated),
        # else the single MAP_MODEL the rest of the tooling already sets.
        resolved_models = models
        if not resolved_models:
            raw = os.environ.get("MAP_MODELS") or os.environ.get("MAP_MODEL", "")
            names = [n.strip() for n in raw.split(",") if n.strip()]
            resolved_models = tuple(ModelEntry(deployment=n, display_name=n) for n in names)

        if not resolved_models:
            raise ProxyConfigError(
                "No models configured. Set MAP_MODEL, or MAP_MODELS for several, "
                "or pass --model. The IDE picker has nothing to show otherwise."
            )

        resolved_port = port or int(os.environ.get("MAP_PROXY_PORT") or DEFAULT_PORT)
        if not (1 <= resolved_port <= 65535):
            raise ProxyConfigError(f"Port must be between 1 and 65535, got {resolved_port}.")

        capture = capture_path or os.environ.get("MAP_PROXY_CAPTURE") or None

        timeout_raw = os.environ.get("MAP_TIMEOUT_SECONDS", "180")
        try:
            timeout = float(timeout_raw)
        except ValueError as exc:
            raise ProxyConfigError(
                f"MAP_TIMEOUT_SECONDS must be numeric, got {timeout_raw!r}"
            ) from exc
        if timeout <= 0:
            raise ProxyConfigError("MAP_TIMEOUT_SECONDS must be greater than zero.")

        return cls(
            gateway_endpoint=endpoint,
            tenant_id=tenant,
            scope=scope_value,
            models=resolved_models,
            port=resolved_port,
            capture_path=capture,
            timeout_seconds=timeout,
        )
