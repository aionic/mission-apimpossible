"""Tests for the schema as APIM actually stores and references it.

`test_request_schema.py` validates the standalone file. That is necessary but
NOT sufficient: Terraform uploads the schema nested under
`components.schemas`, and the policy resolves it with a JSON Pointer. A schema
that is valid standalone can still fail open at runtime if:

  * the policy omits `schema-ref` and validates against the wrapper root, or
  * an internal `$ref` resolves relative to the document root and therefore
    points at nothing once nested.

Both of those were real defects. These tests reconstruct the uploaded document
and validate through the pointer, so the runtime shape is what gets checked.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

import pytest
from jsonschema import Draft7Validator

REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "specs" / "responses-request.schema.json"
POLICY_PATH = REPO_ROOT / "policies" / "responses.xml"
GATEWAY_TF = REPO_ROOT / "infra" / "modules" / "gateway" / "main.tf"

SCHEMA_ID = "responses-request"
EXPECTED_POINTER = f"#/components/schemas/{SCHEMA_ID}"


@pytest.fixture(scope="module")
def raw_schema() -> dict[str, Any]:
    loaded: dict[str, Any] = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    return loaded


@pytest.fixture(scope="module")
def uploaded_document(raw_schema: dict[str, Any]) -> dict[str, Any]:
    """Reconstruct what Terraform uploads.

    Mirrors `components = jsonencode({ schemas = { "<id>" = <schema> } })`
    in infra/modules/gateway/main.tf.
    """
    return {"components": {"schemas": {SCHEMA_ID: raw_schema}}}


@pytest.fixture(scope="module")
def policy_text() -> str:
    return POLICY_PATH.read_text(encoding="utf-8")


# --- The wiring that makes validation actually run ------------------------


def test_policy_declares_schema_ref(policy_text: str) -> None:
    """Without schema-ref the allowlist silently enforces nothing.

    APIM would validate against the uploaded document's root, which is a
    wrapper object with no JSON Schema keywords - so every request would
    pass.

    This lives in responses.xml (the operation policy), not in a fragment:
    schema-id is API-scoped and a fragment has no API context.
    """
    match = re.search(r'schema-ref="([^"]+)"', policy_text)
    assert match, "validate-content must declare schema-ref, or it validates the wrapper root"
    assert match.group(1) == EXPECTED_POINTER


def test_policy_schema_id_matches_terraform() -> None:
    policy_id = re.search(r'schema-id="([^"]+)"', POLICY_PATH.read_text(encoding="utf-8"))
    assert policy_id and policy_id.group(1) == SCHEMA_ID

    tf = GATEWAY_TF.read_text(encoding="utf-8")
    assert f'schema_id           = "{SCHEMA_ID}"' in tf or f'"{SCHEMA_ID}"' in tf


def test_schema_has_no_internal_refs(raw_schema: dict[str, Any]) -> None:
    """Internal $refs resolve against the DOCUMENT root, not the subschema.

    Once nested under components.schemas, a '#/definitions/x' pointer aims at
    a path that does not exist, and that branch of validation fails open.
    Inlining avoids the whole class of problem.
    """
    serialized = json.dumps(raw_schema)
    assert '"$ref"' not in serialized, (
        "internal $ref will not resolve once nested under components.schemas; inline it"
    )


# --- Validation through the pointer, as APIM would do it -----------------


@pytest.fixture(scope="module")
def pointer_validator(uploaded_document: dict[str, Any]) -> Draft7Validator:
    """A validator for the subschema the pointer selects.

    No ref resolver is needed because the schema contains no internal $refs -
    which is itself enforced by test_schema_has_no_internal_refs above.
    """
    subschema = uploaded_document["components"]["schemas"][SCHEMA_ID]
    return Draft7Validator(subschema)


def valid_request(**overrides: Any) -> dict[str, Any]:
    body: dict[str, Any] = {
        "model": "coding-model",
        "input": "Review this function.",
        "store": False,
    }
    body.update(overrides)
    return body


def test_uploaded_schema_accepts_valid_request(pointer_validator: Draft7Validator) -> None:
    assert pointer_validator.is_valid(valid_request())


def test_uploaded_schema_rejects_store_true(pointer_validator: Draft7Validator) -> None:
    assert not pointer_validator.is_valid(valid_request(store=True))


def test_uploaded_schema_rejects_unknown_field(pointer_validator: Draft7Validator) -> None:
    assert not pointer_validator.is_valid(valid_request(tools=[{"type": "web_search"}]))


def test_uploaded_schema_validates_message_array(pointer_validator: Draft7Validator) -> None:
    """The regression that motivated this module.

    With the old '#/definitions/textMessage' $ref, the array branch could not
    resolve once nested and message-level constraints went unenforced.
    """
    assert pointer_validator.is_valid(valid_request(input=[{"role": "user", "content": "hi"}]))
    # Constraints inside the array must still bite.
    assert not pointer_validator.is_valid(valid_request(input=[{"role": "tool", "content": "hi"}]))
    assert not pointer_validator.is_valid(
        valid_request(input=[{"role": "user", "content": "hi", "name": "alice"}])
    )
    assert not pointer_validator.is_valid(valid_request(input=[{"role": "user"}]))


def test_wrapper_root_would_enforce_nothing(uploaded_document: dict[str, Any]) -> None:
    """Demonstrates why schema-ref is mandatory.

    Validating against the uploaded document's ROOT accepts anything, which
    is exactly the failure mode schema-ref prevents.
    """
    root_validator = Draft7Validator(uploaded_document)
    assert root_validator.is_valid(valid_request(store=True, tools=["anything"]))
