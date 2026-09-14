"""Tests for client configuration and correlation.

Config validation is a security boundary here, not ergonomics: the endpoint is
user-supplied and a bearer token gets attached to it.
"""

from __future__ import annotations

import re

import pytest
from map_client.config import ClientConfig, ConfigError
from map_client.correlation import RequestContext

VALID_TENANT = "11111111-2222-3333-4444-555555555555"
VALID_ENDPOINT = "https://apim-map-test.azure-api.net/openai/v1/responses"

GUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
TRACEPARENT_RE = re.compile(r"^00-[0-9a-f]{32}-[0-9a-f]{16}-0[01]$")


@pytest.fixture
def clean_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in (
        "MAP_ENDPOINT",
        "MAP_MODEL",
        "MAP_TENANT_ID",
        "MAP_SCOPE",
        "MAP_TIMEOUT_SECONDS",
    ):
        monkeypatch.delenv(name, raising=False)


def set_valid_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MAP_ENDPOINT", VALID_ENDPOINT)
    monkeypatch.setenv("MAP_MODEL", "coding-model")
    monkeypatch.setenv("MAP_TENANT_ID", VALID_TENANT)


# --- Configuration ---------------------------------------------------------


def test_valid_config_resolves(clean_env: None, monkeypatch: pytest.MonkeyPatch) -> None:
    set_valid_env(monkeypatch)
    config = ClientConfig.from_env()

    assert config.endpoint == VALID_ENDPOINT
    assert config.model == "coding-model"
    assert config.tenant_id == VALID_TENANT
    assert config.scope == "https://ai.azure.com/.default"


def test_base_url_strips_responses_suffix(clean_env: None, monkeypatch: pytest.MonkeyPatch) -> None:
    """The SDK appends /responses; double-appending would 404."""
    set_valid_env(monkeypatch)
    config = ClientConfig.from_env()
    assert config.base_url == "https://apim-map-test.azure-api.net/openai/v1"


def test_http_endpoint_is_refused(clean_env: None, monkeypatch: pytest.MonkeyPatch) -> None:
    """A bearer token must never traverse cleartext.

    The endpoint is user-configurable, so this is checked rather than assumed.
    """
    set_valid_env(monkeypatch)
    monkeypatch.setenv("MAP_ENDPOINT", "http://apim-map-test.azure-api.net/openai/v1/responses")

    with pytest.raises(ConfigError, match="https"):
        ClientConfig.from_env()


@pytest.mark.parametrize("tenant", ["common", "organizations", "not-a-guid", ""])
def test_non_guid_tenant_is_refused(
    clean_env: None, monkeypatch: pytest.MonkeyPatch, tenant: str
) -> None:
    """Single-tenant is a security property, not a default."""
    set_valid_env(monkeypatch)
    monkeypatch.setenv("MAP_TENANT_ID", tenant)

    with pytest.raises(ConfigError):
        ClientConfig.from_env()


def test_missing_values_are_reported_together(
    clean_env: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("MAP_ENDPOINT", VALID_ENDPOINT)

    with pytest.raises(ConfigError) as exc:
        ClientConfig.from_env()

    assert "MAP_MODEL" in str(exc.value)
    assert "MAP_TENANT_ID" in str(exc.value)


@pytest.mark.parametrize("timeout", ["0", "-5", "abc"])
def test_invalid_timeout_is_refused(
    clean_env: None, monkeypatch: pytest.MonkeyPatch, timeout: str
) -> None:
    set_valid_env(monkeypatch)
    monkeypatch.setenv("MAP_TIMEOUT_SECONDS", timeout)

    with pytest.raises(ConfigError):
        ClientConfig.from_env()


def test_config_has_no_api_key_field() -> None:
    """There is no key. If this test starts failing, the design has drifted."""
    assert not any("key" in field.lower() for field in ClientConfig.__dataclass_fields__)


# --- Correlation -----------------------------------------------------------


def test_correlation_id_is_a_guid() -> None:
    assert GUID_RE.match(RequestContext().correlation_id)


def test_traceparent_is_w3c_shaped() -> None:
    assert TRACEPARENT_RE.match(RequestContext().traceparent)


def test_each_context_is_unique() -> None:
    """One request, one identifier. Reuse would break joinability."""
    contexts = [RequestContext() for _ in range(100)]
    assert len({c.correlation_id for c in contexts}) == 100
    assert len({c.trace_id for c in contexts}) == 100
    assert len({c.span_id for c in contexts}) == 100


def test_headers_carry_no_identity_claims() -> None:
    """The gateway strips caller-supplied identity; sending it is pointless.

    This test exists so nobody later 'helpfully' adds x-user-id and assumes
    the gateway will honour it.
    """
    headers = RequestContext().headers()

    assert set(headers) == {"x-correlation-id", "traceparent"}
    for forbidden in ("x-user-id", "x-tenant-id", "x-object-id", "authorization"):
        assert forbidden not in {k.lower() for k in headers}


def test_context_is_immutable() -> None:
    context = RequestContext()
    with pytest.raises(AttributeError):
        context.correlation_id = "tampered"  # type: ignore[misc]
