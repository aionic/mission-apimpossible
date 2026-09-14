"""Policy invariant tests, runnable on any platform.

scripts/validate-policies.ps1 covers the same ground for Windows developers
and the azd preflight hook. This module exists so the same invariants are
enforced in CI without a PowerShell dependency, because these properties are
too important to depend on one runner being available.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
POLICY_DIR = REPO_ROOT / "policies"

COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)


def policy_files() -> list[Path]:
    return sorted(POLICY_DIR.rglob("*.xml"))


def policy_body(path: Path) -> str:
    """Policy text with XML comments removed.

    Comments are stripped because these files legitimately DISCUSS the
    forbidden policies in prose ("there is no authentication-managed-identity
    policy here"). Matching that prose would be a false positive.
    """
    return COMMENT_RE.sub("", path.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def all_policy_text() -> str:
    return "\n".join(policy_body(p) for p in policy_files())


def test_policy_files_exist() -> None:
    assert policy_files(), "no policy files found"


def test_all_policies_are_well_formed_xml() -> None:
    from xml.etree import ElementTree  # noqa: S405

    for path in policy_files():
        # S314 concerns XXE and entity-expansion attacks from UNTRUSTED XML.
        # These are this repository's own committed, reviewed policy files;
        # if they were attacker-controlled, parsing them would be the least
        # of the problems. Parsing is the check itself: it raises on
        # malformed XML, which is exactly what this test asserts.
        ElementTree.parse(path)  # noqa: S314


# --- Negative invariants: these must NEVER appear ------------------------


@pytest.mark.parametrize(
    ("pattern", "why"),
    [
        (
            "authentication-managed-identity",
            "would replace the developer's token with a service identity, "
            "destroying end-to-end human identity",
        ),
        ("authentication-basic", "this architecture uses no shared credentials"),
        (
            "authentication-certificate",
            "would introduce a backend credential distinct from the caller",
        ),
        (
            r'<set-header\s+name="Authorization"',
            "the forwarded token must be byte-identical to the one acquired",
        ),
        (
            "semantic-cache",
            "coding prompts carry proprietary source; cross-user cache hits are "
            "a data-isolation problem",
        ),
        ("log-to-eventhub", "model output must never enter a telemetry path"),
    ],
)
def test_forbidden_policy_is_absent(all_policy_text: str, pattern: str, why: str) -> None:
    assert not re.search(pattern, all_policy_text), f"invariant broken: {why}"


def test_no_api_key_injection(all_policy_text: str) -> None:
    """api-key may be DELETED but never SET.

    The distinction matters: the security-headers fragment deliberately
    deletes it.
    """
    assert not re.search(r'<set-header\s+name="api-key"[^>]*>\s*<value>', all_policy_text)


def test_last_error_message_is_never_emitted(all_policy_text: str) -> None:
    """Raw error text can carry policy source or request fragments."""
    assert "LastError.Message" not in all_policy_text


# --- Positive invariants: these MUST be present --------------------------


def test_sse_forwarding_is_unbuffered() -> None:
    """buffer-response defaults to TRUE, which would break streaming."""
    text = policy_body(POLICY_DIR / "responses.xml")
    assert 'buffer-response="false"' in text


def test_token_validation_is_present() -> None:
    text = policy_body(POLICY_DIR / "fragments" / "authentication.xml")
    assert "validate-azure-ad-token" in text
    # Claims must come from the validated token, never from parsing the raw
    # header.
    assert "output-token-variable-name" in text


def test_app_only_tokens_are_rejected() -> None:
    """tid and oid alone do not distinguish a human from a service principal."""
    text = policy_body(POLICY_DIR / "fragments" / "authentication.xml")
    assert "idtyp" in text
    assert "claim-scp" in text


def test_roles_claim_is_not_used_to_reject() -> None:
    """Humans can hold app roles.

    Rejecting on the presence of 'roles' would lock out legitimate users, so
    the check must target app-only tokens specifically.
    """
    text = policy_body(POLICY_DIR / "fragments" / "authentication.xml")
    assert 'GetValueOrDefault("roles"' not in text
    assert "&quot;roles&quot;" not in text


def test_store_false_is_injected() -> None:
    text = policy_body(POLICY_DIR / "fragments" / "request-validation.xml")
    assert 'body["store"] = false' in text


def test_quota_key_uses_validated_claims() -> None:
    """Keying on anything caller-supplied would let a user escape their counter."""
    auth = policy_body(POLICY_DIR / "fragments" / "authentication.xml")
    governance = policy_body(POLICY_DIR / "fragments" / "token-governance.xml")

    assert "quota-key" in auth
    assert "claim-tid" in auth
    assert "claim-oid" in auth
    assert "quota-key" in governance


def test_spoofable_identity_headers_are_deleted() -> None:
    text = policy_body(POLICY_DIR / "fragments" / "security-headers.xml")
    for header in ("x-user-id", "x-object-id", "x-tenant-id", "x-foundry-request-id"):
        assert re.search(
            rf'<set-header\s+name="{re.escape(header)}"\s+exists-action="delete"',
            text,
        ), f"{header} must be deleted before anything reads it"


def test_metric_dimensions_exclude_object_id() -> None:
    """Custom metric cardinality limits SILENTLY DISCARD data when exceeded."""
    text = policy_body(POLICY_DIR / "fragments" / "token-governance.xml")
    dimensions = re.findall(r'<dimension\s+name="([^"]+)"\s+value="([^"]*)"', text)

    assert dimensions, "expected token metric dimensions"
    for name, value in dimensions:
        assert "oid" not in value, f"dimension {name} must not carry the object ID"
        assert "correlation" not in value.lower()


def test_all_fragment_references_resolve() -> None:
    available = {f"map-{p.stem}" for p in (POLICY_DIR / "fragments").glob("*.xml")}

    for path in policy_files():
        for referenced in re.findall(r'fragment-id="([^"]+)"', path.read_text(encoding="utf-8")):
            assert referenced in available, f"{path.name} references unknown fragment {referenced}"


def test_every_return_response_emits_telemetry() -> None:
    """`return-response` CANCELS the pipeline.

    Neither outbound nor on-error runs after it, so a rejection without an
    inline observability include produces no telemetry at all - and the abuse
    signals behind the app-only-token, unapproved-client, unapproved-model and
    store:true checks would be invisible in Application Insights.

    This regressed once. The fix is only durable if it is enforced.
    """
    for path in policy_files():
        text = policy_body(path)
        # Split on each rejection site; everything before it in that <when>
        # must already have emitted telemetry.
        segments = text.split("<return-response>")
        for index, segment in enumerate(segments[:-1], start=1):
            # Look at the tail of the preceding block, where the set-variable
            # and include-fragment calls live.
            tail = segment[-600:]
            assert 'fragment-id="map-observability"' in tail, (
                f"{path.name}: return-response #{index} is not preceded by a "
                f"map-observability include, so this rejection emits no telemetry"
            )
            assert 'name="rejected-status"' in tail, (
                f"{path.name}: return-response #{index} does not set "
                f"rejected-status, so it would be recorded as status 0"
            )


def test_schema_validation_declares_a_pointer() -> None:
    """Without schema-ref, validate-content checks the wrapper root.

    Terraform uploads the schema nested under components.schemas. Validating
    against that document's root enforces nothing, so the entire request
    allowlist would silently fail open.
    """
    text = policy_body(POLICY_DIR / "fragments" / "request-validation.xml")
    assert 'schema-ref="#/components/schemas/responses-request"' in text
