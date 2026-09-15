"""The session secret and the Entra token.

These are the two credentials in the process, and they are deliberately very
different things:

* The **session secret** authorises use of a local listener. It is worthless
  off this machine, because the listener is unreachable off this machine.
* The **Entra token** is the developer's real identity. It never appears in a
  log, a file, an error message, or a capture.

Neither is ever written to disk.
"""

from __future__ import annotations

import hmac
import logging
import secrets
import threading
import time
from typing import Any, Protocol

logger = logging.getLogger("map_proxy")

# 32 bytes of entropy, URL-safe so it survives being pasted into any settings
# field without escaping surprises.
_SECRET_BYTES = 32

# Refresh this far ahead of expiry. Long enough that a request in flight cannot
# be caught by an expiry mid-call, short enough not to churn.
_REFRESH_SKEW_SECONDS = 300


def generate_session_secret() -> str:
    """Generates the per-session secret the IDE will present."""
    return secrets.token_urlsafe(_SECRET_BYTES)


def secret_matches(presented: str | None, expected: str) -> bool:
    """Constant-time comparison of a presented secret.

    ``==`` on a secret leaks its prefix through timing. That is a marginal risk
    on loopback, where an attacker able to measure it can usually do worse
    already - but the correct comparison costs nothing, and writing the
    incorrect one in a reference sample teaches the wrong lesson.
    """
    if not presented:
        return False
    return hmac.compare_digest(presented, expected)


def extract_presented_secret(authorization: str | None) -> str | None:
    """Pulls the secret out of an Authorization header.

    Accepts ``Bearer <secret>`` and a bare ``<secret>``. Clients vary, and the
    value is checked against a known secret either way, so being lenient about
    the framing costs nothing.
    """
    if not authorization:
        return None
    value = authorization.strip()
    if value.lower().startswith("bearer "):
        return value[7:].strip()
    return value or None


class SupportsGetToken(Protocol):
    """The slice of an azure-identity credential this module needs."""

    def get_token(self, *scopes: str) -> Any: ...


class TokenAcquisitionError(RuntimeError):
    """The developer's token could not be acquired.

    Carries an actionable message: the usual cause is simply not being signed
    in, and telling someone to run ``az login`` is more useful than surfacing
    an SDK traceback.
    """


class TokenProvider:
    """Acquires and caches the developer's Entra access token.

    Thread-safe, because the server handles requests concurrently and a burst
    of them on a cold cache should trigger one sign-in, not several.

    Deliberately holds the token in memory only, for the lifetime of the
    process. There is no token cache on disk to steal.
    """

    def __init__(
        self,
        credential: SupportsGetToken,
        scope: str,
        *,
        clock: Any = time.time,
    ) -> None:
        self._credential = credential
        self._scope = scope
        self._clock = clock
        self._lock = threading.Lock()
        self._token: str | None = None
        self._expires_on: float = 0.0

    @property
    def has_token(self) -> bool:
        """Whether a token is currently cached. Never exposes the token."""
        return self._token is not None

    def get(self) -> str:
        """Returns a valid access token, refreshing when close to expiry.

        Raises:
            TokenAcquisitionError: when no token can be obtained.
        """
        with self._lock:
            now = self._clock()
            if self._token and now < (self._expires_on - _REFRESH_SKEW_SECONDS):
                return self._token

            try:
                result = self._credential.get_token(self._scope)
            except Exception as exc:  # noqa: BLE001 - re-raised with guidance
                raise TokenAcquisitionError(
                    f"Could not acquire a Microsoft Entra token for scope '{self._scope}'. "
                    "The usual cause is not being signed in: run "
                    "`az login --tenant <your tenant>` and try again. "
                    f"Underlying error: {exc}"
                ) from exc

            token = getattr(result, "token", None)
            if not token:
                raise TokenAcquisitionError(
                    "The credential returned no token. Run `az login --tenant <your tenant>`."
                )

            self._token = str(token)
            self._expires_on = float(getattr(result, "expires_on", now + 3600))

            # Log that a refresh happened, never what was refreshed.
            logger.info(
                "Acquired an Entra token; valid for about %d minutes.",
                max(0, int((self._expires_on - now) / 60)),
            )
            return self._token

    def invalidate(self) -> None:
        """Drops the cached token.

        Called when the gateway rejects a token, so the next request acquires a
        fresh one rather than replaying a credential the gateway has already
        refused.
        """
        with self._lock:
            self._token = None
            self._expires_on = 0.0


def build_credential(tenant_id: str) -> SupportsGetToken:
    """Builds a credential pinned to the developer's tenant.

    Explicitly ``AzureCliCredential``, never ``DefaultAzureCredential``.

    The default chain would happily select a managed identity or an environment
    service principal. On a machine where either is present - a jumpbox, a
    build agent, a developer box with stale environment variables - that would
    silently convert a human-identity demonstration into a service-identity
    one, and the whole point of this proxy is that the identity reaching the
    model belongs to a person.

    Failing loudly when the developer is not signed in is the correct
    behaviour, not an inconvenience.
    """
    from azure.identity import AzureCliCredential

    return AzureCliCredential(tenant_id=tenant_id)
