"""Responses client preserving the developer's own Entra identity.

Three decisions here carry real weight:

1. **The credential is explicitly** ``AzureCliCredential``, **not**
   ``DefaultAzureCredential``. The default chain would happily pick up a
   managed identity or an environment service principal. On the private
   pattern's jumpbox a managed identity *is* present, so the default chain
   could silently turn a human-identity demonstration into a service-identity
   one and still appear to work. That would defeat the entire point.

2. **Inference retries are zero.** ``POST /responses`` is not idempotent.
   Retrying after the backend accepted a request can produce duplicate
   inference, duplicate token consumption, and duplicate cost. Token
   *acquisition* retries are a separate matter and are left to the credential.

3. **Tokens are never logged, printed, or persisted.** The client surfaces
   correlation identifiers so a developer can report a problem, and nothing
   that would let someone replay their session.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from azure.identity import AzureCliCredential, get_bearer_token_provider
from openai import OpenAI

from map_client.config import MAX_INPUT_BYTES, ClientConfig
from map_client.correlation import RequestContext


@dataclass(frozen=True)
class TokenUsage:
    """Token counts, with an explicit source.

    ``source`` exists because absent usage and zero usage mean different
    things, and conflating them would silently understate consumption. A
    streamed request that terminates early may never report usage at all.
    """

    input_tokens: int | None = None
    output_tokens: int | None = None
    total_tokens: int | None = None
    source: str = "unavailable"

    @classmethod
    def from_payload(cls, payload: Any) -> TokenUsage:
        if payload is None:
            return cls()
        return cls(
            input_tokens=getattr(payload, "input_tokens", None),
            output_tokens=getattr(payload, "output_tokens", None),
            total_tokens=getattr(payload, "total_tokens", None),
            source="reported",
        )


@dataclass
class InvocationResult:
    """Non-sensitive outcome of one invocation.

    Deliberately carries no token and no raw request. ``output_text`` is the
    model's answer, which the caller asked for; everything else here is
    metadata a developer can safely paste into a support ticket.
    """

    correlation_id: str
    trace_id: str
    foundry_request_id: str | None
    model: str
    status: str
    output_text: str
    input_tokens: int | None = None
    output_tokens: int | None = None
    total_tokens: int | None = None
    usage_source: str = "unavailable"

    def summary(self) -> str:
        """Operator-facing summary. Contains no credential material."""

        def fmt(value: int | None) -> str:
            # Absent usage must never be rendered as zero - they mean
            # different things, and a streamed request may legitimately never
            # report usage at all.
            return str(value) if value is not None else "n/a"

        return "\n".join(
            [
                f"Model              : {self.model}",
                f"Correlation ID     : {self.correlation_id}",
                f"Trace ID           : {self.trace_id}",
                f"Foundry Request ID : {self.foundry_request_id or 'n/a'}",
                f"Status             : {self.status}",
                f"Tokens in/out/total: {fmt(self.input_tokens)}/"
                f"{fmt(self.output_tokens)}/{fmt(self.total_tokens)}",
                f"Usage source       : {self.usage_source}",
            ]
        )


class ResponsesClient:
    """Calls the gateway as the signed-in human."""

    def __init__(self, config: ClientConfig, credential: Any | None = None) -> None:
        self._config = config

        # Pinned to the configured tenant. Without this, a user signed in to
        # several tenants could acquire a token for the wrong one and get a
        # confusing 401 from the gateway rather than a clear local failure.
        self._credential = credential or AzureCliCredential(tenant_id=config.tenant_id)

        # A callable, not a static string: the SDK re-invokes it as the token
        # approaches expiry, so long sessions refresh without re-plumbing.
        token_provider = get_bearer_token_provider(self._credential, config.scope)

        self._client = OpenAI(
            base_url=config.base_url,
            api_key=token_provider,
            timeout=config.timeout_seconds,
            # See decision (2) in the module docstring.
            max_retries=0,
        )

    @staticmethod
    def _validate_input_size(prompt: str, instructions: str | None) -> None:
        size = len(prompt.encode("utf-8"))
        if instructions:
            size += len(instructions.encode("utf-8"))
        if size > MAX_INPUT_BYTES:
            raise ValueError(
                f"Input is {size} bytes, over the {MAX_INPUT_BYTES} byte gateway limit. "
                "Send a narrower excerpt rather than the whole file."
            )

    def _build_request(
        self,
        prompt: str,
        instructions: str | None,
        max_output_tokens: int,
        stream: bool,
    ) -> dict[str, Any]:
        """Assemble a request that satisfies the gateway allowlist.

        ``store`` is sent explicitly as ``False``. The gateway would inject it
        anyway, but stating it makes the stateless intent visible in the
        client code rather than implicit in someone else's policy.
        """
        body: dict[str, Any] = {
            "model": self._config.model,
            "input": prompt,
            "store": False,
            "max_output_tokens": max_output_tokens,
        }
        if instructions:
            body["instructions"] = instructions
        if stream:
            body["stream"] = True
        return body

    def invoke(
        self,
        prompt: str,
        *,
        instructions: str | None = None,
        max_output_tokens: int = 4096,
        context: RequestContext | None = None,
    ) -> InvocationResult:
        """Send a non-streaming request and return the complete answer."""
        ctx = context or RequestContext()
        self._validate_input_size(prompt, instructions)

        body = self._build_request(prompt, instructions, max_output_tokens, stream=False)

        # with_raw_response exposes the response headers, which is how the
        # Foundry request ID is recovered. Without it the support handle is
        # lost.
        raw = self._client.responses.with_raw_response.create(
            extra_headers=ctx.headers(),
            **body,
        )

        response = raw.parse()
        usage = TokenUsage.from_payload(getattr(response, "usage", None))

        return InvocationResult(
            # Prefer the gateway's echoed value: if the client sent a
            # malformed ID the gateway replaced it, and the replacement is the
            # one that appears in telemetry.
            correlation_id=raw.headers.get("x-correlation-id", ctx.correlation_id),
            trace_id=ctx.trace_id,
            foundry_request_id=raw.headers.get("x-foundry-request-id") or None,
            model=self._config.model,
            status=getattr(response, "status", "completed") or "completed",
            output_text=getattr(response, "output_text", "") or "",
            input_tokens=usage.input_tokens,
            output_tokens=usage.output_tokens,
            total_tokens=usage.total_tokens,
            usage_source=usage.source,
        )

    def stream(
        self,
        prompt: str,
        *,
        on_delta: Callable[[str], None],
        instructions: str | None = None,
        max_output_tokens: int = 4096,
        context: RequestContext | None = None,
    ) -> InvocationResult:
        """Stream a response, invoking ``on_delta`` as text arrives.

        Returns the final result. Exceptions propagate normally.

        A callback rather than a generator, deliberately. An earlier version
        yielded the final result from a ``finally:`` block, which silently
        swallowed mid-stream failures: while an exception was propagating the
        ``yield`` suspended the generator, the caller received an ordinary
        result and broke out of the loop, and the pending exception - along
        with ``KeyboardInterrupt`` - was discarded when the generator closed.
        A failed or cancelled request looked like a successful one and exited
        zero. This shape removes that whole class of bug.

        Two streaming realities this surfaces rather than hides:

        * A mid-stream failure can arrive as an SSE error event under HTTP
          200, so a successful status code does not by itself mean the
          generation succeeded. The returned status reflects what happened.
        * Usage may never arrive for an interrupted stream. It is reported as
          ``unavailable`` rather than zero.
        """
        ctx = context or RequestContext()
        self._validate_input_size(prompt, instructions)

        body = self._build_request(prompt, instructions, max_output_tokens, stream=True)

        raw = self._client.responses.with_raw_response.create(
            extra_headers=ctx.headers(),
            **body,
        )

        correlation_id = raw.headers.get("x-correlation-id", ctx.correlation_id)
        foundry_request_id = raw.headers.get("x-foundry-request-id") or None

        status = "incomplete"
        collected: list[str] = []
        usage_payload: Any = None

        # No try/except here. A connection error, timeout, or Ctrl-C must
        # reach the caller, which decides what to do - and deliberately does
        # NOT resend, because the backend may already have consumed tokens.
        for event in raw.parse():
            event_type = getattr(event, "type", "")

            if event_type == "response.output_text.delta":
                delta = getattr(event, "delta", "") or ""
                collected.append(delta)
                on_delta(delta)

            elif event_type == "response.completed":
                status = "completed"
                response = getattr(event, "response", None)
                usage_payload = getattr(response, "usage", None) if response else None

            elif event_type == "response.incomplete":
                status = "incomplete"

            elif event_type == "error":
                # An error event under HTTP 200. Record it as a terminal
                # failure rather than reporting apparent success.
                status = "failed"

        usage = TokenUsage.from_payload(usage_payload)
        return InvocationResult(
            correlation_id=correlation_id,
            trace_id=ctx.trace_id,
            foundry_request_id=foundry_request_id,
            model=self._config.model,
            status=status,
            output_text="".join(collected),
            input_tokens=usage.input_tokens,
            output_tokens=usage.output_tokens,
            total_tokens=usage.total_tokens,
            usage_source=usage.source,
        )


def format_gateway_error(body: str) -> str:
    """Render a gateway error for a human.

    The gateway returns a deliberately generic message plus a correlation ID.
    That is by design: a detailed error would leak backend URLs, resource IDs,
    or policy internals. The correlation ID is what makes it diagnosable.
    """
    try:
        parsed = json.loads(body)
        error = parsed.get("error", {})
        code = error.get("code", "unknown")
        message = error.get("message", "No detail provided.")
        correlation = error.get("correlation_id", "n/a")
        return f"{code}: {message}\nCorrelation ID: {correlation}"
    except (json.JSONDecodeError, AttributeError):
        return "The gateway returned an error that could not be parsed."
