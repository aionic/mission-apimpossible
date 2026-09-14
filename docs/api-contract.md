# The request contract

The gateway exposes exactly one operation:

```http
POST /openai/v1/responses
```

No wildcard route, no `/chat/completions`, no `/assistants`, no `/agents`, no
model listing, no stored-response retrieval, and no `api-version` parameter.

## Why an allowlist

The Responses API is treated as an **allowlisted enterprise API, not an
unrestricted proxy**. This endpoint carries proprietary source code, so the
default posture is that a feature is unavailable until someone has written down
what it does and what it risks.

Adding a field to [`responses-request.schema.json`](../specs/responses-request.schema.json)
requires a documented threat model. That is the whole point.

## Accepted fields

| Field | Type | Bound | Notes |
| --- | --- | --- | --- |
| `model` | string | ≤ 64 chars | Must equal the approved deployment. Re-checked by policy. |
| `input` | string **or** text message array | 48 KiB / 40 messages | Client-maintained history only. |
| `instructions` | string | 8 KiB | Optional. |
| `stream` | boolean | — | SSE, forwarded unbuffered. |
| `store` | boolean | must be `false` | Rejected if `true`; injected if omitted. |
| `max_output_tokens` | integer | 1–4096 | Model may impose lower. |
| `temperature` | number | 0–2 | Omit for reasoning models. |
| `top_p` | number | 0–1 | Optional. |
| `reasoning.effort` | enum | — | `minimal`/`low`/`medium`/`high`. |
| `metadata` | object | ≤ 8 string values | Never used for authorization. |

`additionalProperties` is `false` at every level. Unknown fields — including
fields Azure adds in future — are rejected rather than silently forwarded.

## Rejected by default

| Rejected | Why |
| --- | --- |
| `store: true` | Would persist proprietary source server-side. Rejected rather than silently rewritten, so developer intent is never quietly changed. |
| `previous_response_id`, `conversation` | Server-side conversation state. The client keeps context locally. |
| `background` | Asynchronous execution outside the request's governance and correlation window. |
| `tools`, `functions`, `tool_choice` | External interaction. Requires a per-tool allowlist and threat model. |
| Remote MCP servers | External interaction with an unvetted endpoint. |
| `computer-use` | Grants the model control of an environment. |
| File, image, audio, PDF input parts | Payload exfiltration and content-handling surface. |
| URL-bearing input structures | Server-side fetch of attacker-influenced URLs. |
| Prompt references / prompt templates | Server-side stored artifacts. |
| `multi_agent`, `context_management` | Enables server-side compaction and subagent execution. |
| Preview opt-in headers | The sample demonstrates GA functionality. |
| Any unknown property | Fail closed on features that did not exist at review time. |

> A URL typed inside a plain `input` string is inert text — the model may read
> it, but nothing fetches it. Prohibiting *URL-bearing features* is not the same
> as prohibiting the characters `https://` in a prompt, and this document does
> not claim otherwise.

## `store` handling, precisely

| Client sends | Gateway behavior | Status |
| --- | --- | --- |
| `"store": false` | Forwarded unchanged | 200 |
| field omitted | `"store": false` injected before forwarding | 200 |
| `"store": true` | **Rejected** | 400 |
| `"store": null` | Rejected | 400 |
| `"store": "false"` (string) | Rejected | 400 |

Rejecting explicit `true` rather than rewriting it is deliberate: silently
flipping a developer's stated intent hides a security-relevant decision from
them.

## Size limits

| Limit | Value | Reason |
| --- | --- | --- |
| HTTP request body | 64 KiB | Below every documented APIM ceiling. See gate G7. |
| Aggregate input + instructions | 48 KiB | Bounds what a single request can carry. |
| Message array | 40 entries | Bounds client-side history replay. |
| `max_output_tokens` | 4096 | Bounds cost per request. |

The documented ceilings conflict — the `validate-content` reference permits
4 MB while the gateway runtime table lists 100 KiB for validated bodies. The
conservative value is used until tested; see gate G7.

## Status codes

| Condition | Status |
| --- | --- |
| Success | 200 |
| Missing bearer token | 401 |
| Invalid, expired, or wrong-audience token | 401 |
| **Wrong tenant** | **401** |
| App-only token or unapproved client application | 403 |
| Valid human without Foundry RBAC | 403 |
| Malformed body, unknown field, `store:true`, oversized | 400 |
| Unapproved model | 400 |
| Per-user TPM exceeded | 429 + `Retry-After` |
| Per-user daily quota exceeded | 429 *(normalized)* or 403 *(native)* |
| Backend unavailable | 502 / 503 |
| Backend timeout | 504 |

### Two deviations from the original brief, both deliberate

**Wrong tenant returns 401, not 403.** `validate-azure-ad-token` is configured
with a literal tenant, so a wrong-tenant token simply fails validation, and the
policy's failure code applies to *all* validation failures uniformly. Producing
403 only for tenant mismatch would require inspecting an **unvalidated** `tid`
claim to choose a status — reading attacker-controlled data before
authentication. The safe rule is: authentication failures are 401;
authorization failures on an already-validated identity are 403.

**Daily quota normalization is conditional.** `llm-token-limit` natively
returns 429 for TPM but **403** for daily quota. Normalizing that 403 to 429 is
only done where a reliable policy-origin signal distinguishes it from an RBAC
403. Blanket-remapping every 403 would mask genuine authorization failures.
Until proven (gate G5), the native 403 stands and is documented.

`x-correlation-id` is returned on every response where the gateway can emit
headers, including errors.

## Error body

```json
{
  "error": {
    "code": "store_not_permitted",
    "message": "This gateway enforces stateless operation. Remove 'store' or set it to false.",
    "correlation_id": "78e5a796-0f30-472d-8491-ce2d857850ad"
  }
}
```

Never included: backend URLs, subscription or resource IDs, JWT claims the
client does not already own, APIM internals, policy source, or stack traces.

## Retries

The gateway performs **no** automatic retry of an inference POST. `POST
/responses` is not idempotent; retrying after the backend accepted a request can
produce duplicate inference, duplicate token consumption, and duplicate cost.

Clients set SDK retries to zero and retry only intentionally, respecting
`Retry-After`. Token *acquisition* retries are separate and permitted.
