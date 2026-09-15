"""Tests for the proxy's credential handling.

The session secret and the Entra token are the two credentials in the process,
and the properties asserted here are the ones that make the design defensible:
the secret is compared safely and rejected when wrong, and the token is
refreshed, invalidated on rejection, and never exposed.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import pytest
from map_proxy.tokens import (
    TokenAcquisitionError,
    TokenProvider,
    extract_presented_secret,
    generate_session_secret,
    secret_matches,
)


@dataclass
class _FakeToken:
    token: str
    expires_on: float


class _FakeCredential:
    """Records how often a token was requested."""

    def __init__(self, *, expires_on: float = 10_000.0, fail: bool = False) -> None:
        self.calls = 0
        self._expires_on = expires_on
        self._fail = fail

    def get_token(self, *scopes: str) -> Any:
        self.calls += 1
        if self._fail:
            raise RuntimeError("Please run 'az login'")
        return _FakeToken(token=f"token-{self.calls}", expires_on=self._expires_on)


class TestSessionSecret:
    def test_generated_secrets_are_unique(self) -> None:
        assert generate_session_secret() != generate_session_secret()

    def test_generated_secret_has_meaningful_entropy(self) -> None:
        # 32 random bytes, URL-safe encoded. Short enough to paste, long
        # enough that guessing it is not a strategy.
        assert len(generate_session_secret()) >= 40

    def test_correct_secret_matches(self) -> None:
        secret = generate_session_secret()
        assert secret_matches(secret, secret)

    @pytest.mark.parametrize("presented", ["", None, "wrong", "  "])
    def test_wrong_or_missing_secret_is_rejected(self, presented: str | None) -> None:
        assert not secret_matches(presented, generate_session_secret())

    def test_a_prefix_of_the_secret_is_rejected(self) -> None:
        # The property that matters for a timing-safe comparison: a partial
        # match must be no more acceptable than a total mismatch.
        secret = generate_session_secret()
        assert not secret_matches(secret[:-1], secret)


class TestPresentedSecretExtraction:
    def test_bearer_prefix_is_stripped(self) -> None:
        assert extract_presented_secret("Bearer abc123") == "abc123"

    def test_bearer_is_case_insensitive(self) -> None:
        assert extract_presented_secret("bearer abc123") == "abc123"

    def test_bare_value_is_accepted(self) -> None:
        # Clients vary in framing, and the value is checked against a known
        # secret either way, so leniency here costs nothing.
        assert extract_presented_secret("abc123") == "abc123"

    @pytest.mark.parametrize("header", [None, "", "   "])
    def test_absent_header_yields_none(self, header: str | None) -> None:
        assert extract_presented_secret(header) is None


class TestTokenProvider:
    def test_first_call_acquires(self) -> None:
        credential = _FakeCredential()
        provider = TokenProvider(credential, "scope", clock=lambda: 0.0)
        assert provider.get() == "token-1"
        assert credential.calls == 1

    def test_second_call_uses_the_cache(self) -> None:
        credential = _FakeCredential()
        provider = TokenProvider(credential, "scope", clock=lambda: 0.0)
        provider.get()
        provider.get()
        assert credential.calls == 1

    def test_token_is_refreshed_before_it_expires(self) -> None:
        # Refreshing only at expiry would let a request in flight be caught by
        # it, so the provider refreshes with a margin.
        credential = _FakeCredential(expires_on=1000.0)
        now = 0.0
        provider = TokenProvider(credential, "scope", clock=lambda: now)

        assert provider.get() == "token-1"

        now = 800.0  # inside the 300s refresh skew
        assert provider.get() == "token-2"
        assert credential.calls == 2

    def test_invalidate_forces_a_fresh_acquisition(self) -> None:
        # Used when the gateway rejects a token: the next request must not
        # replay a credential the gateway has already refused.
        credential = _FakeCredential()
        provider = TokenProvider(credential, "scope", clock=lambda: 0.0)

        assert provider.get() == "token-1"
        provider.invalidate()
        assert provider.get() == "token-2"

    def test_has_token_reflects_state_without_exposing_it(self) -> None:
        provider = TokenProvider(_FakeCredential(), "scope", clock=lambda: 0.0)
        assert not provider.has_token
        provider.get()
        assert provider.has_token
        provider.invalidate()
        assert not provider.has_token

    def test_signed_out_raises_with_actionable_guidance(self) -> None:
        provider = TokenProvider(_FakeCredential(fail=True), "scope", clock=lambda: 0.0)

        with pytest.raises(TokenAcquisitionError) as exc:
            provider.get()

        # The overwhelmingly common cause is simply not being signed in, so
        # the message must say so rather than surfacing an SDK traceback.
        assert "az login" in str(exc.value)

    def test_a_credential_returning_no_token_is_an_error(self) -> None:
        class _Empty:
            def get_token(self, *scopes: str) -> Any:
                return _FakeToken(token="", expires_on=1.0)

        provider = TokenProvider(_Empty(), "scope", clock=lambda: 0.0)
        with pytest.raises(TokenAcquisitionError):
            provider.get()
