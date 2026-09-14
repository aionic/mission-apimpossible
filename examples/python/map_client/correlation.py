"""Per-request correlation and W3C trace context.

Two identifiers travel with every request, and they do different jobs:

* ``x-correlation-id`` is an application-owned GUID. A human can read it off
  the screen and quote it in a support request. It is telemetry only and is
  never used for authentication, authorization, or routing.

* ``traceparent`` is W3C trace context. It lets Azure Monitor establish the
  parent/child relationship between the gateway's frontend request and its
  backend dependency.

Neither replaces the other, which is why both are sent.
"""

from __future__ import annotations

import os
import uuid
from dataclasses import dataclass, field

_TRACE_VERSION = "00"
# Sampled. The reference environments run at full sampling to prove
# correlation; production deployments lower it at the gateway.
_TRACE_FLAGS = "01"


def _new_trace_id() -> str:
    """32 lowercase hex characters, per W3C Trace Context."""
    return uuid.uuid4().hex


def _new_span_id() -> str:
    """16 lowercase hex characters, per W3C Trace Context."""
    return os.urandom(8).hex()


@dataclass(frozen=True)
class RequestContext:
    """Correlation identifiers for a single invocation.

    Frozen because reusing or mutating these across requests would break the
    one-request-one-identifier property that makes the telemetry joinable.
    """

    correlation_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    trace_id: str = field(default_factory=_new_trace_id)
    span_id: str = field(default_factory=_new_span_id)

    @property
    def traceparent(self) -> str:
        return f"{_TRACE_VERSION}-{self.trace_id}-{self.span_id}-{_TRACE_FLAGS}"

    def headers(self) -> dict[str, str]:
        """Correlation headers for this request.

        Note what is absent: no identity headers. The gateway derives identity
        exclusively from the validated token and strips any caller-supplied
        ``x-user-id``, ``x-tenant-id``, or similar. Sending them would be
        pointless at best and misleading at worst.
        """
        return {
            "x-correlation-id": self.correlation_id,
            "traceparent": self.traceparent,
        }
