"""Regression tests for streaming error propagation.

An earlier `stream()` yielded its final result from a `finally:` block. When
an exception was propagating, that yield suspended the generator, the consumer
received an ordinary result and broke out of the loop, and the pending
exception was discarded when the generator closed.

The practical effect: a mid-stream connection failure, timeout, or Ctrl-C was
reported to the user as a normal result with exit code 0.

These tests pin the corrected behaviour - exceptions reach the caller.
"""

from __future__ import annotations

from typing import Any

import pytest
from map_client.config import ClientConfig
from map_client.responses import ResponsesClient

CONFIG = ClientConfig(
    endpoint="https://gateway.test/openai/v1/responses",
    model="coding-model",
    tenant_id="11111111-2222-3333-4444-555555555555",
    scope="https://ai.azure.com/.default",
)


class _Event:
    def __init__(self, type_: str, **kwargs: Any) -> None:
        self.type = type_
        for key, value in kwargs.items():
            setattr(self, key, value)


class _FakeStream:
    """Stands in for the SDK's Stream, which is a context manager.

    Tracking `closed` lets the tests assert the response is released even when
    iteration raises - otherwise an aborted stream would leave the underlying
    HTTP connection open until the traceback was collected.
    """

    def __init__(self, events: Any) -> None:
        self._events = events
        self.closed = False

    def __enter__(self) -> Any:
        return self._events

    def __exit__(self, *_: Any) -> None:
        self.closed = True
        # Returning None (never True) so exceptions always reach the caller.


class _FakeRawResponse:
    """Stands in for the SDK's raw streaming response."""

    def __init__(self, events: Any, headers: dict[str, str]) -> None:
        self.stream = _FakeStream(events)
        self.headers = headers

    def parse(self) -> _FakeStream:
        return self.stream


def _client_yielding(events: Any) -> tuple[ResponsesClient, dict[str, Any]]:
    """A client whose transport replays the given event sequence.

    Returns the client plus a handle exposing the fake stream, so tests can
    assert the response was closed.
    """
    client = ResponsesClient.__new__(ResponsesClient)
    client._config = CONFIG

    handle: dict[str, Any] = {}

    class _Responses:
        class _WithRaw:
            @staticmethod
            def create(**_: Any) -> _FakeRawResponse:
                raw = _FakeRawResponse(
                    events,
                    {
                        "x-correlation-id": "78e5a796-0f30-472d-8491-ce2d857850ad",
                        "x-foundry-request-id": "foundry-abc",
                    },
                )
                handle["raw"] = raw
                return raw

        with_raw_response = _WithRaw()

    class _Inner:
        responses = _Responses()

    client._client = _Inner()  # type: ignore[assignment]
    return client, handle


def test_successful_stream_returns_result() -> None:
    events = [
        _Event("response.output_text.delta", delta="Hello "),
        _Event("response.output_text.delta", delta="world"),
        _Event(
            "response.completed",
            response=_Event(
                "response",
                usage=_Event("usage", input_tokens=10, output_tokens=5, total_tokens=15),
            ),
        ),
    ]

    received: list[str] = []
    client, _ = _client_yielding(events)
    result = client.stream("hi", on_delta=received.append)

    assert received == ["Hello ", "world"]
    assert result.output_text == "Hello world"
    assert result.status == "completed"
    assert result.usage_source == "reported"
    assert result.total_tokens == 15
    assert result.foundry_request_id == "foundry-abc"


def test_midstream_exception_reaches_the_caller() -> None:
    """The regression. A transport failure must NOT look like success."""

    def events() -> Any:
        yield _Event("response.output_text.delta", delta="partial")
        raise ConnectionError("connection reset by peer")

    received: list[str] = []
    client, handle = _client_yielding(events())
    with pytest.raises(ConnectionError, match="connection reset"):
        client.stream("hi", on_delta=received.append)

    # The caller still saw what arrived before the failure.
    assert received == ["partial"]
    # And the HTTP response was released rather than left open until the
    # traceback was collected.
    assert handle["raw"].stream.closed


def test_keyboard_interrupt_reaches_the_caller() -> None:
    """Ctrl-C must propagate so the CLI can report cancellation and exit 130.

    It must also NOT trigger a resend: the backend may already have consumed
    tokens for this request.
    """

    def events() -> Any:
        yield _Event("response.output_text.delta", delta="partial")
        raise KeyboardInterrupt

    client, handle = _client_yielding(events())
    with pytest.raises(KeyboardInterrupt):
        client.stream("hi", on_delta=lambda _: None)

    assert handle["raw"].stream.closed


def test_sse_error_event_under_http_200_is_terminal_failure() -> None:
    """A 200 status does not prove the generation succeeded."""
    events = [
        _Event("response.output_text.delta", delta="partial"),
        _Event("error"),
    ]

    client, _ = _client_yielding(events)
    result = client.stream("hi", on_delta=lambda _: None)

    assert result.status == "failed"
    assert result.output_text == "partial"


def test_missing_usage_is_unavailable_not_zero() -> None:
    """Absent usage and zero usage mean different things."""
    events = [
        _Event("response.output_text.delta", delta="text"),
        _Event("response.completed", response=_Event("response", usage=None)),
    ]

    client, _ = _client_yielding(events)
    result = client.stream("hi", on_delta=lambda _: None)

    assert result.usage_source == "unavailable"
    assert result.total_tokens is None
    assert "n/a" in result.summary()


def test_stream_without_completion_event_is_incomplete() -> None:
    events = [_Event("response.output_text.delta", delta="truncated")]

    client, _ = _client_yielding(events)
    result = client.stream("hi", on_delta=lambda _: None)

    assert result.status == "incomplete"
    assert result.usage_source == "unavailable"
