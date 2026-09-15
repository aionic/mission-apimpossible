"""Tests for the loopback listener.

These cover the two things the listener is responsible for: refusing anything
that does not present the session secret, and advertising only models the
gateway would actually accept.

Forwarding is deliberately not mocked here. It is a byte-for-byte passthrough,
and a test double proving that bytes survive a function call would assert
nothing useful - that path is proven live against the real gateway instead.
"""

from __future__ import annotations

from typing import Any

import pytest
from aiohttp.test_utils import TestClient, TestServer
from aiohttp.web import Application, Request
from map_proxy.config import ModelEntry, ProxyConfig
from map_proxy.server import build_app
from map_proxy.tokens import TokenProvider, generate_session_secret

SECRET = generate_session_secret()


class _FakeToken:
    token = "fake-access-token"
    expires_on = 10_000.0


class _FakeCredential:
    def get_token(self, *scopes: str) -> Any:
        return _FakeToken()


def _config() -> ProxyConfig:
    return ProxyConfig(
        gateway_endpoint="https://example.azure-api.net/openai/v1/responses",
        tenant_id="00000000-1111-2222-3333-444444444444",
        scope="https://ai.azure.com/.default",
        models=(
            ModelEntry(deployment="coding-model", display_name="Coding model"),
            ModelEntry(deployment="second-model", display_name="Second model"),
        ),
        port=0,
    )


@pytest.fixture
async def client() -> Any:
    config = _config()
    tokens = TokenProvider(_FakeCredential(), config.scope, clock=lambda: 0.0)
    app = build_app(config, tokens, SECRET, None)
    async with TestClient(TestServer(app)) as test_client:
        yield test_client


class TestAuthorisation:
    async def test_request_without_a_key_is_rejected(
        self, client: TestClient[Request, Application]
    ) -> None:
        response = await client.get("/v1/models")
        assert response.status == 401

    async def test_request_with_a_wrong_key_is_rejected(
        self, client: TestClient[Request, Application]
    ) -> None:
        response = await client.get(
            "/v1/models", headers={"Authorization": "Bearer not-the-secret"}
        )
        assert response.status == 401

    async def test_a_prefix_of_the_key_is_rejected(
        self, client: TestClient[Request, Application]
    ) -> None:
        response = await client.get(
            "/v1/models", headers={"Authorization": f"Bearer {SECRET[:-1]}"}
        )
        assert response.status == 401

    async def test_correct_key_is_accepted(self, client: TestClient[Request, Application]) -> None:
        response = await client.get("/v1/models", headers={"Authorization": f"Bearer {SECRET}"})
        assert response.status == 200

    async def test_bare_key_without_bearer_is_accepted(
        self, client: TestClient[Request, Application]
    ) -> None:
        response = await client.get("/v1/models", headers={"Authorization": SECRET})
        assert response.status == 200

    async def test_rejection_is_shaped_like_an_openai_error(
        self, client: TestClient[Request, Application]
    ) -> None:
        # The IDE parses this. An unrecognisable body surfaces as an opaque
        # failure rather than "your key is wrong".
        response = await client.get("/v1/models")
        body = await response.json()
        assert body["error"]["code"] == "invalid_api_key"

    async def test_rejection_does_not_reveal_why(
        self, client: TestClient[Request, Application]
    ) -> None:
        # Absent, malformed and simply-wrong must be indistinguishable.
        absent = await (await client.get("/v1/models")).json()
        wrong = await (
            await client.get("/v1/models", headers={"Authorization": "Bearer nope"})
        ).json()
        assert absent == wrong

    async def test_the_secret_never_appears_in_a_rejection(
        self, client: TestClient[Request, Application]
    ) -> None:
        response = await client.get("/v1/models", headers={"Authorization": "Bearer nope"})
        assert SECRET not in await response.text()


class TestModels:
    async def test_lists_every_configured_deployment(
        self, client: TestClient[Request, Application]
    ) -> None:
        response = await client.get("/v1/models", headers={"Authorization": f"Bearer {SECRET}"})
        body = await response.json()
        assert [m["id"] for m in body["data"]] == ["coding-model", "second-model"]

    async def test_uses_the_openai_list_envelope(
        self, client: TestClient[Request, Application]
    ) -> None:
        # The IDE expects data[] with .id on each entry; anything else is
        # reported as an invalid response.
        response = await client.get("/v1/models", headers={"Authorization": f"Bearer {SECRET}"})
        body = await response.json()
        assert body["object"] == "list"
        assert all("id" in m for m in body["data"])


class TestRouting:
    async def test_unknown_paths_are_not_served(
        self, client: TestClient[Request, Application]
    ) -> None:
        # Two endpoints exist. A general-purpose proxy would be a far larger
        # thing to reason about.
        response = await client.get(
            "/v1/chat/completions", headers={"Authorization": f"Bearer {SECRET}"}
        )
        assert response.status == 404

    async def test_responses_rejects_get(self, client: TestClient[Request, Application]) -> None:
        response = await client.get("/v1/responses", headers={"Authorization": f"Bearer {SECRET}"})
        assert response.status == 405
