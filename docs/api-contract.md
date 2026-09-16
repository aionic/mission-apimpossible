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
| `model` | string | ≤ 64 chars | Must equal an approved deployment. Re-checked by policy. |
| `input` | string **or** message array | 768 KiB / 1000 items | Client-maintained history only. `content` may be a plain string or the canonical `[{type:"input_text", text}]` array. |
| `instructions` | string | 8 KiB | Optional. |
| `stream` | boolean | — | SSE, forwarded unbuffered. |
| `store` | boolean | must be `false` | Rejected if `true`; injected if omitted. |
| `max_output_tokens` | integer | 1–32768 | The model imposes its own, usually lower, ceiling. |
| `temperature` | number | 0–2 | Omit for reasoning models. |
| `top_p` | number | 0–1 | Optional. |
| `reasoning.effort` | enum | — | `minimal`/`low`/`medium`/`high`. |
| `truncation` | enum | `auto`/`disabled` | Transient context handling. Not persistence: `store:false` still applies. |
| `tools` | array | ≤ 256, `type:"function"` only | **Client-side** tools. Name ≤ 128 chars, description ≤ 32 KiB. |
| `tool_choice` | string or object | `auto`/`none`/`required`, or a named function | — |
| `parallel_tool_calls` | boolean | — | Execution still happens on the caller's machine. |
| `metadata` | object | ≤ 8 string values | Never used for authorization. |

Message items may also be `function_call` and `function_call_output`, so a
client can replay its own tool loop. Both are bounded and neither is
interpreted by the gateway.

`additionalProperties` is `false` at every level. Unknown fields — including
fields Azure adds in future — are rejected rather than silently forwarded.

> **These bounds are measured, not chosen.** A single GitHub Copilot agent turn
> sends roughly 138 KB of input across 8–10 items with 88–90 tool definitions,
> the largest description running to 5,859 characters. The original bounds —
> 48 KiB, 40 items, 4,096-character descriptions — were invented, and rejected
> every one of those requests. See gate G7 in
> [platform validation](platform-validation.md).

## Rejected by default

| Rejected | Why |
| --- | --- |
| `store: true` | Would persist proprietary source server-side. Rejected rather than silently rewritten, so developer intent is never quietly changed. |
| `previous_response_id`, `conversation` | Server-side conversation state. The client keeps context locally. |
| `background` | Asynchronous execution outside the request's governance and correlation window. |
| **Hosted tools** — `code_interpreter`, `file_search`, `mcp`, `computer_use`, `web_search` | They move execution to the **service**. The boundary this contract defends is not "no tools", it is "no server-side execution". Rejected unconditionally, in schema *and* policy, with no switch to relax it. |
| `functions` | The superseded shape. Unreviewed; use `tools`. |
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

## Recommended configuration

> Full reference for every setting: [configuration](configuration.md).

The defaults suit one developer evaluating the pattern. Adopting it for a team
means changing two things that are easy to confuse, because they scale
differently.

**Per-user limits are per person.** `tokens_per_minute` and
`daily_token_quota` are keyed on `tid:oid`, so adding developers does not
consume them faster. They bound what *one* person can do.

**Model capacity is shared.** The deployment's TPM is consumed by everyone at
once. This is what actually runs out as a team grows, and when it does, Foundry
throttles — not the gateway.

Sizing tables, per-scenario guidance and the quota command live in
[configuration](configuration.md#model). The short version: per-user limits do
not scale with team size; `model_capacity` does, and it is what runs out.
**`max_output_tokens` deserves thought.** The gateway permits up to 32,768. A
coding agent writing a file needs several thousand; the original 4,096 ceiling
truncated answers rather than failing visibly, which is the worst outcome — the
caller receives something that looks complete and is not. Set it as low as the
work allows, because it directly bounds cost per request, but do not set it
below what a real task needs.

**What not to tune.** The size bounds and the tool limits were measured from
real IDE traffic, not chosen. Lowering them will reject legitimate requests;
the original conservative values rejected every GitHub Copilot request that
reached them. Raise them only if a client genuinely needs more.

## Size limits

| Limit | Value | Reason |
| --- | --- | --- |
| HTTP request body | 1 MiB | **512 KiB proven** against the deployed gateway. See gate G7. |
| `input` text | 768 KiB | Bounds what a single request can carry. |
| Message array | 1000 entries | Bounds client-side history replay. |
| `tools` | 256 entries | An IDE sends its whole catalogue; 88–90 measured. |
| Tool description | 32 KiB | Longest measured: 5,859 characters. |
| `max_output_tokens` | 32768 | Bounds cost per request. 4096 truncated real coding work. |

The documented ceilings conflict — `validate-content` permits 4 MB, the gateway
runtime table lists 100 KiB for validated bodies, and v2 has a separate 2 MiB
buffered-payload limit. That contradiction was originally resolved by picking
the smallest, 64 KiB.

**Measurement settled it.** `scripts/probe-size-ceiling.ps1` passes 512 KiB
through the deployed gateway without difficulty, so the 100 KiB figure does not
apply to this path. Caution derived from an inapplicable limit is not caution,
it is a gateway no IDE can use.

## Rate limits

| Limit | Value | Notes |
| --- | --- | --- |
| Tokens per minute | 1,000,000 | Per `tid:oid`. One agent turn can cost ~30,000. |
| Daily token quota | 50,000,000 | Fixed UTC day, not a rolling window. |
| Concurrent requests | 12 | Per user. Overshoots by gateway node count — see G5. |

These were originally 20,000 / 100,000 / 2, which is a single-prompt budget: one
IDE agent turn exceeded the entire per-minute ceiling, and the daily quota
allowed about three requests.

Quotas remain operational safeguards, not billing controls. Azure Cost
Management is the financial source of truth.

## Status codes

| Condition | Status |
| --- | --- |
| Success | 200 |
| Missing bearer token | 401 |
| Invalid, expired, or wrong-audience token | 401 |
| **Wrong tenant** | **401** |
| App-only token or unapproved client application | 403 `not_delegated_identity` / `unapproved_client` |
| Valid human not authorised for this gateway | 403 `not_authorized` |
| Valid human without Foundry RBAC | 403 — **`passthrough` mode only.** In `brokered` mode no human holds RBAC, so entitlement is decided by the gateway instead |
| Hosted tool requested | 400 `hosted_tool_not_permitted` |
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
