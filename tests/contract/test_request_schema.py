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
        ("tools", [{"type": "web_search"}], "SERVER-SIDE execution"),
        ("tools", [{"type": "code_interpreter"}], "SERVER-SIDE execution"),
        ("tools", [{"type": "file_search"}], "SERVER-SIDE execution"),
        ("tools", [{"type": "mcp", "server_url": "https://x"}], "SERVER-SIDE execution"),
        ("tools", [{"type": "computer_use_preview"}], "SERVER-SIDE execution"),
        ("functions", [{"name": "f"}], "superseded, unreviewed shape"),
        ("prompt", {"id": "pmpt_1"}, "server-side stored artifact"),
        ("multi_agent", {"enabled": True}, "server-side subagent execution"),
        ("context_management", {"compact_threshold": 100}, "server-side compaction"),
        ("truncation", "auto", "not reviewed"),
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


# ---------------------------------------------------------------------------
# Client-side tools: accepted. Hosted tools: never.
#
# The boundary that matters is NOT "no tools" - it is "no SERVER-SIDE
# execution". A client-side function tool is an ordinary request/response as
# far as the service is concerned: the model asks, the CALLER decides whether
# to run it, and execution happens on the developer's machine. A hosted tool
# moves execution into the service, which is the thing this contract exists to
# prevent.
#
# Copilot hides models without tool calling from agent mode - the DEFAULT mode
# - so refusing all tools made the gateway effectively invisible in normal use.
# ---------------------------------------------------------------------------


def test_client_side_function_tool_is_accepted(validator: Draft7Validator) -> None:
    assert is_valid(
        validator,
        valid_request(
            tools=[
                {
                    "type": "function",
                    "name": "read_file",
                    "description": "Read a file from the workspace.",
                    "parameters": {
                        "type": "object",
                        "properties": {"path": {"type": "string"}},
                    },
                }
            ]
        ),
    )


@pytest.mark.parametrize("choice", ["auto", "none", "required"])
def test_tool_choice_strings_are_accepted(validator: Draft7Validator, choice: str) -> None:
    assert is_valid(validator, valid_request(tool_choice=choice))


def test_tool_choice_can_name_a_function(validator: Draft7Validator) -> None:
    assert is_valid(validator, valid_request(tool_choice={"type": "function", "name": "read_file"}))


def test_tool_choice_cannot_name_a_hosted_tool(validator: Draft7Validator) -> None:
    assert not is_valid(
        validator, valid_request(tool_choice={"type": "web_search", "name": "search"})
    )


def test_a_tool_without_a_type_is_rejected(validator: Draft7Validator) -> None:
    # Absent type must not be treated as "probably a function".
    assert not is_valid(validator, valid_request(tools=[{"name": "read_file"}]))


def test_one_hosted_tool_poisons_an_otherwise_valid_list(
    validator: Draft7Validator,
) -> None:
    # Validation is per item, so a hosted tool hidden among legitimate ones
    # must still fail the whole request.
    assert not is_valid(
        validator,
        valid_request(
            tools=[
                {"type": "function", "name": "ok"},
                {"type": "code_interpreter"},
            ]
        ),
    )


def test_function_call_and_result_items_are_accepted(validator: Draft7Validator) -> None:
    # The client replaying its own tool loop: the model asked, the client ran
    # it locally, and this is the result going back.
    body = valid_request()
    body["input"] = [
        {"role": "user", "content": "What is in config.json?"},
        {
            "type": "function_call",
            "call_id": "call_abc123",
            "name": "read_file",
            "arguments": '{"path": "config.json"}',
        },
        {"type": "function_call_output", "call_id": "call_abc123", "output": "{}"},
    ]
    assert is_valid(validator, body)


def test_tool_arguments_must_be_a_string_not_an_object(
    validator: Draft7Validator,
) -> None:
    # The Responses API carries arguments as a JSON STRING. Accepting an object
    # would let a caller smuggle arbitrary structure past a bounded field.
    body = valid_request()
    body["input"] = [
        {
            "type": "function_call",
            "call_id": "call_abc123",
            "name": "read_file",
            "arguments": {"path": "config.json"},
        }
    ]
    assert not is_valid(validator, body)


def test_a_function_call_item_cannot_carry_extra_properties(
    validator: Draft7Validator,
) -> None:
    body = valid_request()
    body["input"] = [
        {
            "type": "function_call",
            "call_id": "c1",
            "name": "f",
            "arguments": "{}",
            "server_url": "https://evil.example",
        }
    ]
    assert not is_valid(validator, body)
