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
    # The bound is large because a real IDE needs it to be - GitHub Copilot
    # was measured sending 133 KB of input in a single agent-mode turn - but
    # it is still a bound, and it is still enforced.
    assert not is_valid(validator, valid_request(input="x" * 786433))


def test_too_many_messages_is_rejected(validator: Draft7Validator) -> None:
    body = valid_request(input=[{"role": "user", "content": "hi"} for _ in range(401)])
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


# ---------------------------------------------------------------------------
# The shape a real IDE actually sends.
#
# These are written from a CAPTURED GitHub Copilot agent-mode request, not from
# the specification. The gateway had been rejecting every one of them:
#
#   content_forms      ["array"]           - canonical typed parts, not strings
#   content_part_types ["input_text"]
#   input_item_types   ["message"]         - items carry an explicit type
#   input_bytes        136211              - 133 KB in ONE turn
#   tool_count         88                  - the whole tool catalogue, per request
#   outside allowlist  ["truncation"]
#
# Guessing produced a schema that looked reasonable and worked with nothing.
# ---------------------------------------------------------------------------


def test_canonical_content_parts_are_accepted(validator: Draft7Validator) -> None:
    body = valid_request()
    body["input"] = [
        {
            "type": "message",
            "role": "user",
            "content": [{"type": "input_text", "text": "Review this function."}],
        }
    ]
    assert is_valid(validator, body)


def test_plain_string_content_is_still_accepted(validator: Draft7Validator) -> None:
    # The simple form must keep working - the curl and Python examples use it,
    # and breaking them to satisfy an IDE would be a poor trade.
    body = valid_request()
    body["input"] = [{"role": "user", "content": "Review this function."}]
    assert is_valid(validator, body)


def test_assistant_output_text_parts_are_accepted(validator: Draft7Validator) -> None:
    body = valid_request()
    body["input"] = [
        {
            "type": "message",
            "role": "assistant",
            "content": [{"type": "output_text", "text": "Looks fine."}],
        }
    ]
    assert is_valid(validator, body)


def test_item_level_id_and_status_are_tolerated(validator: Draft7Validator) -> None:
    # Echoed back by clients replaying history. Bounded, never interpreted.
    body = valid_request()
    body["input"] = [
        {
            "type": "message",
            "id": "msg_abc123",
            "status": "completed",
            "role": "user",
            "content": [{"type": "input_text", "text": "hi"}],
        }
    ]
    assert is_valid(validator, body)


@pytest.mark.parametrize("part_type", ["input_image", "input_file", "input_audio"])
def test_non_text_content_parts_are_rejected(
    validator: Draft7Validator, part_type: str
) -> None:
    # The text-only boundary is unchanged by widening the shape. An attachment
    # must be REJECTED rather than silently dropped, so the caller knows the
    # model never saw it.
    body = valid_request()
    body["input"] = [
        {
            "type": "message",
            "role": "user",
            "content": [{"type": part_type, "text": "x"}],
        }
    ]
    assert not is_valid(validator, body)


def test_an_unknown_item_type_is_rejected(validator: Draft7Validator) -> None:
    body = valid_request()
    body["input"] = [{"type": "reasoning", "role": "assistant", "content": "x"}]
    assert not is_valid(validator, body)


def test_truncation_is_bounded_to_known_values(validator: Draft7Validator) -> None:
    assert is_valid(validator, valid_request(truncation="auto"))
    assert is_valid(validator, valid_request(truncation="disabled"))
    assert not is_valid(validator, valid_request(truncation="middle_out"))


def test_a_realistic_agent_tool_catalogue_is_accepted(
    validator: Draft7Validator,
) -> None:
    # 88 tools were measured on a single request; the bound must clear that
    # with room, or agent mode fails the moment somebody installs an extension.
    tools = [
        {
            "type": "function",
            "name": f"tool_{i}",
            "description": "x" * 200,
            "parameters": {"type": "object", "properties": {"a": {"type": "string"}}},
        }
        for i in range(88)
    ]
    assert is_valid(validator, valid_request(tools=tools))


def test_a_real_world_tool_description_is_accepted(validator: Draft7Validator) -> None:
    """The single field that rejected every GitHub Copilot agent request.

    The bound was 4096, invented rather than measured. VS Code's
    ``run_in_terminal`` tool ships a 5,859-character description - tool
    descriptions are prompt engineering, not labels - so one tool out of 88
    failed the whole request, and the gateway's sanitised error could not say
    which. Finding it needed a local capture and offline validation.
    """
    tools = [
        {
            "type": "function",
            "name": "run_in_terminal",
            "description": "x" * 5859,
            "parameters": {"type": "object", "properties": {}},
            "strict": None,
        }
    ]
    assert is_valid(validator, valid_request(tools=tools))


def test_mcp_style_tool_names_are_accepted(validator: Draft7Validator) -> None:
    # Measured longest from a real catalogue: 56 characters. MCP-namespaced
    # names concatenate server and tool identifiers, so they grow with nesting.
    tools = [
        {
            "type": "function",
            "name": "activate_fallback_mcp_pylance_mcp_s_pylancePythonDebug_1",
            "parameters": {"type": "object", "properties": {}},
        }
    ]
    assert is_valid(validator, valid_request(tools=tools))


def test_tool_bounds_still_exist(validator: Draft7Validator) -> None:
    # Raising a bound because reality needed it is not the same as removing it.
    assert not is_valid(
        validator,
        valid_request(tools=[{"type": "function", "name": "x", "description": "y" * 32769}]),
    )
    assert not is_valid(
        validator, valid_request(tools=[{"type": "function", "name": "x" * 129}])
    )
    assert not is_valid(
        validator, valid_request(tools=[{"type": "function", "name": "has space"}])
    )
