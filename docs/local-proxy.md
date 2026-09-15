# The local Entra proxy

> Status: **design agreed, not yet implemented.** This document is the contract
> the implementation must satisfy. Tracked as `map-41a` in beads.

## The problem

Goal 1 of this repository is finished and proven: a developer calls a Foundry
model through API Management using their own Microsoft Entra identity. Every
request is attributable to a human, there is no key to leak, and access follows
Conditional Access and ordinary joiner/mover/leaver process.

Goal 2 is to use that same endpoint from an IDE.

Almost every IDE that supports a custom model offers the same thing: a base URL
and a static secret. GitHub Copilot's Custom Endpoint, Cursor, Continue, and
the OpenAI SDKs all assume a key. None of them can perform an interactive Entra
sign-in, none understand tenants, and none can refresh a token that expires in
an hour.

So the gateway is unusable from the tools developers actually work in — not
because of anything the gateway does wrong, but because its authentication
model is better than the one those tools expect.

## The approach

A small local process presents a key-shaped surface to the IDE and forwards the
developer's real Entra token to the gateway.

```
IDE  ──127.0.0.1, local secret──▶  proxy  ──Bearer <developer Entra token>──▶  APIM  ──▶  Foundry
```

The IDE believes it is talking to an ordinary key-authenticated provider. The
request that leaves the machine carries the developer's own identity, and the
gateway sees exactly what it always saw.

The demonstration this produces is the point: **Copilot running in
bring-your-own-key mode, where the key is not a key — it is Entra.**

## What the proxy must not do

It forwards the request body **unchanged, byte for byte**. It does not
translate protocols, rewrite fields, inject defaults, or interpret content.

This is the single most important constraint in the design, and it is worth
being explicit about why. The gateway is where the request contract is
enforced: the allowlist, the size bounds, the model allowlist, the `store=false`
rule. Those enforcement points have been tested against a live deployment and
their behaviour is documented in `platform-validation.md`. Every byte the proxy
rewrites is a byte whose validation happens somewhere other than where it is
proven — and a local process that quietly disagrees with the gateway is a
source of bugs nobody will think to look for.

The proxy changes the credential. That is all it changes.

### Why no protocol translation is needed

The obvious assumption is that Copilot only speaks Chat Completions, and that
the proxy must therefore translate between that and the Responses API. It does
not.

Copilot's Custom Endpoint provider supports an `apiType` of `responses`, which
makes it send Responses-shaped requests to `/v1/responses` — exactly the shape
the gateway already accepts. Setting `zeroDataRetentionEnabled: true`
additionally makes VS Code send `store: false` and never chain
`previous_response_id`, which matches the gateway's contract for free.

Checking this before building saved a translation layer that would have needed
maintaining forever.

## Why this is not the authentication shim the design forbids

The project's non-negotiables (`docs/implementation-plan.md`, section 3) rule
out an authentication shim, alongside OBO and API keys. That rule deserves to
be taken seriously rather than lawyered around, so here is the distinction in
full.

The forbidden thing is a **server-side** component that substitutes one
identity for another: a service account calling on behalf of users, an OBO
exchange, a shared key at the front door. All of them break attribution, which
is the property this entire design exists to preserve. After such a shim, the
gateway can no longer tell you which human made a request.

This proxy:

- runs on the developer's own machine, as the developer;
- uses the developer's own interactive Entra sign-in;
- forwards the developer's own token, unmodified;
- holds no credential that represents anybody else;
- is reachable only from that machine.

It substitutes no identity. Attribution in Application Insights is unchanged —
`tid:oid` still resolves to the human, and the per-user token limits still key
on them. It is a courier, not a broker.

That said, the distinction is doing real work, so the costs are stated below
rather than buried.

### Recorded as an explicit exception

This is an approved exception to the "no authentication shim" rule, not a
reinterpretation of it. It carries its own threat-model entry
(`docs/threat-model.md`, T-LOOPBACK) and the residual risks below.

## Security model

### The local secret

A random secret is generated each time the proxy starts. The developer pastes
it into the IDE's key field once per session.

| Property | Decision |
| --- | --- |
| Generation | Cryptographically random, per process start |
| Storage | Memory only. Never written to disk, never logged |
| Comparison | Constant time, to avoid a timing oracle |
| Lifetime | Dies with the process |
| Value if stolen | None off-machine: the listener is unreachable remotely |

The secret is not a credential for anything in Azure. It authorises use of a
local listener, nothing more.

### The listener

| Control | Decision |
| --- | --- |
| Bind address | `127.0.0.1` explicitly, IPv4 only. Never `0.0.0.0`, never `localhost` |
| Transport | Plain HTTP. TLS on loopback would need a trusted local certificate, which is worse than the problem it solves |
| Methods | `POST /v1/responses` and `GET /v1/models`. Nothing else |
| Token handling | Acquired per request, held in memory, never logged |

`localhost` is deliberately avoided in favour of `127.0.0.1`: it can resolve to
`::1` first, and a mismatch between what the IDE resolves and what the proxy
binds produces a confusing connection failure.

### Residual risks

**Any process running as this user can call the proxy while it is running.**
That is inherent to a loopback listener. The secret raises the bar — a process
must also read it from the IDE's storage or the proxy's output — but it does
not eliminate the risk. Malware already executing as the developer can
impersonate the IDE.

This is a genuine widening of the attack surface compared with goal 1, where
the only thing that could call the gateway was something that already held the
developer's token. It is accepted because the alternative is that the gateway
cannot be used from an IDE at all.

**The proxy can request inference as the developer for as long as it runs.**
It holds a live token. Mitigated by keeping the process short-lived and
foreground, rather than installing it as a background service.

## Consequences for the gateway

Only two changes are required, and both are driven by the IDE rather than by
the proxy.

### Multiple approved deployments

The model allowlist currently pins exactly one deployment name and compares
with equality. A picker with one entry is not a picker, so the allowlist
becomes a set and the comparison becomes membership.

This does not weaken anything: an unlisted deployment is still rejected, and
the set is still declared in configuration rather than discovered.

### The canonical input shape

`input[].content` currently must be a plain string. The canonical Responses
format is an array of typed parts — `[{"type": "input_text", "text": "..."}]`.
If the IDE sends the canonical form, every request is rejected.

The schema will accept both, staying text-only and bounded. Image, audio and
file parts remain rejected: that boundary is unchanged.

**This will be driven by captured evidence rather than assumption.** The proxy
gets a capture mode, and the schema changes to match what the IDE actually
sends. Guessing at wire formats is how the first version of this plan ended up
with a translation layer it did not need.

## Accepted limitations

**Tool calling is not enabled.** Copilot hides models without `toolCalling`
from agent mode, so these models appear in ask mode only.

This is a deliberate trade. Enabling tools would mean widening the Responses
allowlist, and the strict surface currently has an empirical proof behind it —
fourteen hostile request shapes, all failing closed, documented under gate G7.
Ask mode is enough to demonstrate the identity story, which is the point of the
sample. Client-side function tools remain a possible future addition; hosted
tools, which move execution to the service, do not.

**No inline completions.** VS Code does not route inline suggestions to custom
models; that path stays on GitHub's infrastructure regardless of this proxy.

**One tenant, one gateway.** The proxy is configured with a single gateway
endpoint and tenant, matching the deployment it was generated for.

## Open questions

| Question | How it gets answered |
| --- | --- |
| Does the IDE send `content` as a string or the canonical array? | Capture mode, before the schema is touched |
| Does it exceed the 8 KiB `instructions` cap? | Capture mode |
| Does it exceed the 48 KiB aggregate input bound in normal use? | Capture mode, over a realistic session |
| Does `zeroDataRetentionEnabled` reliably produce `store: false`? | Capture mode; the gateway rejects the request if not |

## Related

- `docs/architecture/mission-apimpossible-ide-proxy.mmd` — the architecture contract
- `docs/identity-modes.md` — brokered versus passthrough, unchanged by this
- `docs/threat-model.md` — T-LOOPBACK
- `docs/platform-validation.md` — gate G7, the strict-surface proofs this preserves
