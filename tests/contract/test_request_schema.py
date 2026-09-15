"""Contract tests for the request allowlist.

These are the tests that matter most. The schema is the security boundary
between "a developer sends a prompt" and "a developer reaches a Responses
feature nobody threat-modelled", so each rejection below corresponds to a
specific thing that must not be reachable.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest
from jsonschema import Draft7Validator

SCHEMA_PATH = Path(__file__).resolve().parents[2] / "specs" / "responses-request.schema.json"
APPROVED_MODEL = "coding-model"


@pytest.fixture(scope="module")
def validator() -> Draft7Validator:
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    Draft7Validator.check_schema(schema)
    return Draft7Validator(schema)


def valid_request(**overrides: Any) -> dict[str, Any]:
    body: dict[str, Any] = {
        "model": APPROVED_MODEL,
        "input": "Review this function.",
        "store": False,
    }
    body.update(overrides)
    return body


def is_valid(validator: Draft7Validator, body: dict[str, Any]) -> bool:
    valid: bool = validator.is_valid(body)
    return valid


# --- Happy path ------------------------------------------------------------


def test_minimal_request_is_accepted(validator: Draft7Validator) -> None:
    assert is_valid(validator, valid_request())


def test_full_allowlisted_request_is_accepted(validator: Draft7Validator) -> None:
    body = valid_request(
        instructions="Be concise.",
        stream=True,
        max_output_tokens=2048,
        reasoning={"effort": "medium"},
        metadata={"ticket": "ABC-123"},
    )
    assert is_valid(validator, body)


def test_text_message_history_is_accepted(validator: Draft7Validator) -> None:
    """Client-maintained context, which is how statelessness stays usable."""
    body = valid_request(
        input=[
            {"role": "user", "content": "What does this do?"},
            {"role": "assistant", "content": "It sorts a list."},
            {"role": "user", "content": "Is it stable?"},
        ]
    )
    assert is_valid(validator, body)


# --- store: the stateless guarantee ---------------------------------------


def test_store_true_is_rejected(validator: Draft7Validator) -> None:
    """The single most important rejection.

    This endpoint carries proprietary source. Server-side persistence must be
    unreachable, and it is rejected rather than silently rewritten so a
    developer is never left believing something untrue about where their code
    went.
    """
    assert not is_valid(validator, valid_request(store=True))


@pytest.mark.parametrize("value", [None, "false", "False", 0, 1, [], {}])
def test_store_must_be_literal_boolean_false(validator: Draft7Validator, value: Any) -> None:
    """Truthiness games must not sneak past the check."""
    assert not is_valid(validator, valid_request(store=value))


def test_store_may_be_omitted(validator: Draft7Validator) -> None:
    """Omission is legal; the gateway injects false before forwarding."""
    body = {"model": APPROVED_MODEL, "input": "hello"}
    assert is_valid(validator, body)


# --- Features that introduce external interaction or persistence ----------


@pytest.mark.parametrize(
    ("field", "value", "why"),
    [
        ("previous_response_id", "resp_abc123", "server-side conversation state"),
        ("conversation", {"id": "conv_1"}, "server-side conversation state"),
        ("background", True, "async execution outside the governance window"),
        ("tools", [{"type": "web_search"}], "external interaction"),
        ("tool_choice", "auto", "external interaction"),
        ("functions", [{"name": "f"}], "external interaction"),
        ("prompt", {"id": "pmpt_1"}, "server-side stored artifact"),
        ("multi_agent", {"enabled": True}, "server-side subagent execution"),
        ("context_management", {"compact_threshold": 100}, "server-side compaction"),
        ("truncation", "auto", "not reviewed"),
        ("parallel_tool_calls", True, "external interaction"),
        ("include", ["reasoning.encrypted_content"], "not reviewed"),
        ("service_tier", "flex", "not reviewed"),
    ],
)
def test_unapproved_feature_is_rejected(
    validator: Draft7Validator, field: str, value: Any, why: str
) -> None:
    assert not is_valid(validator, valid_request(**{field: value})), (
        f"{field} must be rejected ({why})"
    )


def test_unknown_future_field_is_rejected(validator: Draft7Validator) -> None:
    """Fail closed on features that did not exist at review time.

    additionalProperties:false is what makes this repository safe against
    Azure shipping a new Responses capability next month.
    """
    assert not is_valid(validator, valid_request(some_field_invented_in_2027=True))


# --- Input shape -----------------------------------------------------------


def test_file_input_part_is_rejected(validator: Draft7Validator) -> None:
    body = valid_request(
        input=[{"role": "user", "content": [{"type": "input_file", "file_id": "f_1"}]}]
    )
    assert not is_valid(validator, body)


def test_image_input_part_is_rejected(validator: Draft7Validator) -> None:
    body = valid_request(
        input=[
            {
                "role": "user",
                "content": [{"type": "input_image", "image_url": "https://example.test/x.png"}],
            }
        ]
    )
    assert not is_valid(validator, body)


def test_unknown_role_is_rejected(validator: Draft7Validator) -> None:
    body = valid_request(input=[{"role": "tool", "content": "result"}])
    assert not is_valid(validator, body)


def test_extra_message_property_is_rejected(validator: Draft7Validator) -> None:
    body = valid_request(input=[{"role": "user", "content": "hi", "name": "alice"}])
    assert not is_valid(validator, body)


def test_url_inside_plain_text_is_accepted(validator: Draft7Validator) -> None:
    """A URL typed in a prompt is inert text.

    Prohibiting URL-bearing *features* is not the same as prohibiting the
    characters 'https://' in a prompt, and this repository does not pretend
    otherwise. Nothing fetches it.
    """
    body = valid_request(input="What does https://example.test/spec say about retries?")
    assert is_valid(validator, body)


def test_empty_input_is_rejected(validator: Draft7Validator) -> None:
    assert not is_valid(validator, valid_request(input=""))


def test_oversized_input_is_rejected(validator: Draft7Validator) -> None:
    assert not is_valid(validator, valid_request(input="x" * 49153))


def test_too_many_messages_is_rejected(validator: Draft7Validator) -> None:
    body = valid_request(input=[{"role": "user", "content": "hi"} for _ in range(41)])
    assert not is_valid(validator, body)


# --- Bounds ----------------------------------------------------------------


def test_model_is_required(validator: Draft7Validator) -> None:
    assert not is_valid(validator, {"input": "hello", "store": False})


def test_input_is_required(validator: Draft7Validator) -> None:
    assert not is_valid(validator, {"model": APPROVED_MODEL, "store": False})


@pytest.mark.parametrize("value", [0, -1, 4097, 100000])
def test_max_output_tokens_bounds(validator: Draft7Validator, value: int) -> None:
    assert not is_valid(validator, valid_request(max_output_tokens=value))


@pytest.mark.parametrize("value", [-0.1, 2.1])
def test_temperature_bounds(validator: Draft7Validator, value: float) -> None:
    assert not is_valid(validator, valid_request(temperature=value))


def test_unknown_reasoning_effort_is_rejected(validator: Draft7Validator) -> None:
    assert not is_valid(validator, valid_request(reasoning={"effort": "extreme"}))


def test_unknown_reasoning_property_is_rejected(validator: Draft7Validator) -> None:
    assert not is_valid(validator, valid_request(reasoning={"summary": "detailed"}))


def test_model_name_injection_shape_is_rejected(validator: Draft7Validator) -> None:
    """The pattern bounds what can reach the policy's model comparison."""
    assert not is_valid(validator, valid_request(model="../../other-deployment"))
    assert not is_valid(validator, valid_request(model="model name with spaces"))
