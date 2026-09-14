# Observability

One principle: **you can reconstruct who called the model, when, and what
happened — without ever seeing what they asked.**

## The correlation chain

Three identifiers travel with each request, doing different jobs:

| Identifier | Origin | Purpose |
| --- | --- | --- |
| `x-correlation-id` | Client (or gateway, if invalid) | A GUID a human can quote in a support ticket |
| `traceparent` / trace ID | Client | W3C context; becomes `operation_Id` in Application Insights |
| Gateway request ID | `context.RequestId` | APIM's own identifier, distinct from both above |
| `apim-request-id` | Foundry response | Microsoft's support handle for the backend call |

### What joins, and what does not

```text
client x-correlation-id
    → APIM frontend request (operation_Id)
        → APIM backend dependency
            → captured Foundry apim-request-id   ← chain ends here
```

**The chain ends at the gateway.** The Foundry request ID lets you raise a
support case with Microsoft. It is **not** a joinable trace segment, and no
first-party source establishes that Foundry exposes internal spans to the
caller or that `x-ms-client-request-id` is queryable downstream.

The gateway sends `x-ms-client-request-id` opportunistically because it costs
nothing. The documentation does not claim you can query it. See gate G6 in
[`platform-validation.md`](platform-validation.md).

### Correlation ID handling

| Client sends | Gateway does |
| --- | --- |
| Valid GUID | Preserves it end to end |
| Malformed / oversized / absent | Replaces with a fresh GUID |

The value is **telemetry only**. It is never used for authentication,
authorization, quota keying, or routing — so a caller controlling it gains
nothing. The gateway bounds and pattern-checks it before use so an injection
attempt is replaced rather than echoed.

## What is never logged

Absolute, at every verbosity level:

- `Authorization` headers and bearer tokens
- Prompt text and source code
- Model output
- Tool arguments and file contents
- UPNs, email addresses, display names
- Raw `LastError.Message`, backend response bodies
- Backend URLs, resource IDs, subscription IDs, policy source

Enforced by:

- **Zero body bytes on all four diagnostic legs** — frontend and backend,
  request and response. Microsoft warns that even *request-body* diagnostic
  logging can disrupt SSE, so this protects streaming as well as privacy.
- **Header allowlist** carrying only correlation identifiers.
- **Fixed trace messages** with structured metadata; nothing user-controlled
  is interpolated into a message body.
- **Foundry diagnostics** enable only `Audit` and `AzureOpenAIRequestUsage`.
  `allLogs` is never enabled and `RequestResponse` / `Trace` are explicitly
  excluded.

> A category name does not establish that its contents are payload-free. That
> is why the exclusions are explicit and why enabling more categories requires
> schema review first (gate G10).

### Identifiers that *are* recorded

`tid` and `oid` — protected pseudonymous identifiers, in access-controlled
logs. Deliberately **not** UPNs or display names. Resolving an object ID to a
person requires a separate Entra lookup, which is intended friction.

## Metrics vs logs

| | Metrics | Logs |
| --- | --- | --- |
| Dimensions | Environment, model, streaming, API | Full metadata record |
| Contains `oid` | **Never** | Yes, protected |
| Purpose | Aggregate trends | Per-request investigation |

`oid` is excluded from metrics because custom metrics allow 100 values per
dimension and 1,000 active series per namespace — and **exceeding those limits
silently discards data**. A high-cardinality dimension would not error; it
would quietly lose telemetry.

## Token accounting, honestly

These numbers are operational, **not billing-grade**:

| Reality | Consequence |
| --- | --- |
| Streaming prompt tokens are **always estimated** | Not affected by configuration |
| Usage may be **absent** for interrupted streams | Absent ≠ zero, and is recorded as `unavailable` |
| Counters are **per gateway** | Concurrent requests can overshoot |
| Remaining-quota headers are an **estimate** | Documented as such |
| Application Insights is **not an audit system** | Microsoft states this explicitly |

`usage.source` in [`telemetry.schema.json`](../specs/telemetry.schema.json) is
`reported`, `estimated`, `partial`, or `unavailable`. Queries must not sum
across these as though they were equivalent.

**Azure Cost Management is the financial source of truth.**

## Streaming caveats

- A mid-stream failure can arrive as an **SSE error event under HTTP 200**.
  Status code alone does not prove generation succeeded, which is why the
  telemetry record carries a separate `outcome`.
- For streaming, gateway duration runs to stream termination. It is **not**
  model think time and **not** time-to-first-token.
- The gateway never reads the response body, so streamed usage is delivered
  in-band to the client and recorded as `unavailable` server-side rather than
  guessed at.

## Queries

| File | Answers |
| --- | --- |
| [`correlation.kql`](../queries/correlation.kql) | Everything about one correlation ID |
| [`user-activity.kql`](../queries/user-activity.kql) | Calls per Entra principal |
| [`token-usage.kql`](../queries/token-usage.kql) | Consumption trends + accounting confidence |
| [`failures.kql`](../queries/failures.kql) | 4xx/5xx grouped by cause |
| [`throttling.kql`](../queries/throttling.kql) | Who is limited, and by which limit |
| [`latency.kql`](../queries/latency.kql) | Gateway overhead vs model time |

### Sampling

Reference environments run at **100%** to prove correlation works. Lower
`telemetry_sampling_percentage` for production volume — but note that sampling
breaks the guarantee that any given correlation ID is findable.

## Verifying privacy after deployment

1. Send a request containing a unique canary string.
2. Confirm the request **succeeded** and telemetry arrived. *An empty search
   result because ingestion is broken is not a pass.*
3. Search every table for the canary:

```kusto
let canary = "CANARY-e3f1a9-DO-NOT-LOG";
union traces, requests, dependencies, exceptions, customEvents, customMetrics
| where timestamp > ago(1h)
| where * has canary
| project timestamp, itemType, operation_Id
```

Expect **zero rows**. Repeat with verbosity raised and with a *rejected*
request, since validation errors and automatic exception telemetry are
separate paths from normal request logging.
