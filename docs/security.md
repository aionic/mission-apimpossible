# Security

Every control here is stated with its **limit**. A control described without
its boundary is a liability in a security review, because the reviewer will
find the boundary anyway.

## Identity

### Authentication

The developer's own Microsoft Entra access token authenticates the request.
APIM validates it with `validate-azure-ad-token` against a **literal tenant
GUID** — `common` and `organizations` are rejected by Terraform variable
validation, so this cannot be widened by configuration drift.

Validated: signature, expiry, issuer, tenant, audience.

### Proving the caller is a human

`tid` and `oid` alone do **not** distinguish a human from a service principal —
service principals have both. Authorization therefore requires:

| Check | Why |
| --- | --- |
| Token validates | Baseline |
| `scp` present | Issued only on delegated user tokens |
| `idtyp != "app"` | Explicitly marks app-only tokens |
| `tid` and `oid` present and single-valued | Forms the quota key |
| `azp` / `appid` on the allowlist | Approved client applications only |

**Deliberately not a rejection criterion:** the presence of a `roles` claim.
Humans can hold app roles, so rejecting on `roles` would lock out legitimate
users.

> **Limit.** This establishes a *delegated user identity*. It does not prove a
> person is at the keyboard. A stolen token within its validity window is
> indistinguishable from the legitimate user — see
> [`threat-model.md`](threat-model.md).

### Token preservation

The original `Authorization` header is forwarded **unchanged**. There is no
`authentication-managed-identity` policy, no backend credential, no API key,
and no OBO exchange anywhere in the repository.

Enforced mechanically by `tests/contract/test_policy_invariants.py` and
`scripts/validate-policies.ps1`, both of which fail the build if a
credential-substituting policy appears.

### The three identities

| Identity | Permissions | Can call the model? |
| --- | --- | --- |
| Developer (human) | `Cognitive Services OpenAI User` on the account | **Yes** |
| APIM managed identity | `Monitoring Metrics Publisher` on App Insights | No |
| Jumpbox managed identity | Entra VM sign-in only | No |

> **Limit.** `Cognitive Services OpenAI User` is the least-privileged
> **built-in** role containing `.../OpenAI/responses/*`. It is nonetheless
> broader than "POST /responses only" — it also covers completions,
> embeddings, images, assistants, and video. A narrower custom role is a
> documented hardening option, not a default, because it must first be proven
> not to break the Responses call path.

### Credential selection in clients

The Python client uses `AzureCliCredential` pinned to the tenant, **not**
`DefaultAzureCredential`. The default chain would happily select a managed
identity or environment service principal — and on the private pattern's
jumpbox a managed identity *is* present. The demo would still appear to work
while proving nothing.

## Request governance

### Stateless operation

| Client sends | Gateway | Status |
| --- | --- | --- |
| `store: false` | Forwarded | 200 |
| omitted | `store: false` injected | 200 |
| `store: true` | **Rejected** | 400 |
| `null`, `"false"`, `0` | Rejected | 400 |

Rejection rather than silent rewriting is deliberate: quietly flipping a
developer's stated intent hides a security-relevant decision from them.

> **Limit.** `store:false` governs *Responses storage*. It is **not** a claim
> that every service-side abuse-monitoring mechanism is disabled. Abuse
> monitoring is a separate Azure OpenAI feature with its own process.

### Feature allowlist

`specs/responses-request.schema.json` sets `additionalProperties: false` at
every level. Features that did not exist at review time fail closed.

Rejected: tools, functions, MCP, computer use, file/image/audio inputs,
URL-bearing structures, `previous_response_id`, `conversation`, `background`,
prompt references, `multi_agent`, `context_management`, preview opt-in headers.

> **Limit.** A URL typed inside a plain text prompt is inert — nothing fetches
> it. Prohibiting URL-bearing *features* is not the same as banning the
> characters `https://` in a prompt, and the documentation does not claim
> otherwise.

### Model allowlist

Exactly one deployment exists, and policy independently rejects any other
`model` value. The schema constrains the *shape*; the policy constrains the
*value*.

### Size limits

| Limit | Value |
| --- | --- |
| Request body | 64 KiB |
| Aggregate input + instructions | 48 KiB |
| Message history | 40 entries |
| `max_output_tokens` | 4096 |

> **Limit.** The documented APIM ceilings **conflict** — the `validate-content`
> reference permits 4 MB while the gateway runtime table lists 100 KiB for
> validated bodies. 64 KiB sits below every documented value. Behavior with
> chunked, compressed, or missing-`Content-Length` requests is untested (gate
> G7).

### Header control

Deleted before anything reads them: `x-user-id`, `x-object-id`, `x-tenant-id`,
`x-ms-client-principal*`, `x-foundry-request-id`, `x-apim-*`, `api-key`,
`Ocp-Apim-Subscription-Key`, preview opt-in headers, and routing overrides.

> **Limit.** A perfect allowlist is **not achievable**. `set-header` cannot
> alter or delete `Connection`, `Content-Length`, `Keep-Alive`, or
> `Transfer-Encoding`; it cannot remove the client-IP component of
> `X-Forwarded-For`; and it cannot delete the response `Server` header. These
> are platform limitations, stated rather than papered over.

### Rate and quota limits

Keyed on validated `tid:oid` — never a subscription key, because the Entra
principal is the consumer and this gateway issues no subscription keys.

> **Limit — read before using these numbers financially.** Quotas are
> operational safeguards, **not billing controls**:
>
> - streaming prompt tokens are **always estimated**, regardless of config;
> - counters are **per gateway**, so concurrent requests can overshoot;
> - remaining-quota headers are documented as an **estimate**;
> - `Daily` is a **fixed UTC calendar day**, not a rolling window;
> - daily quota exhaustion natively returns **403**, not 429.
>
> **Azure Cost Management is the financial source of truth.**

## Network

### Public pattern

APIM and Foundry are publicly reachable with Entra enforced and no keys.

> **Accepted residual risk.** A developer holding inference RBAC can call
> Foundry directly, bypassing every gateway control. This is stated, not
> hidden. Use the private pattern to prevent it.

### Private pattern

> **A private endpoint alone does not stop an authorized developer.** Private
> endpoints are reachable from peered VNets, VPN, and ExpressRoute under the
> default `AllowVNetInBound` rule.

The control is an explicit NSG on the Foundry PE subnet with
`private_endpoint_network_policies` enabled (without which the NSG is simply
not evaluated for PE traffic):

| Priority | Source | Action |
| --- | --- | --- |
| 100 | `snet-apim-integration` | Allow 443 |
| 200 | `snet-jump` | **Deny** |
| 210 | corporate prefixes | **Deny** |
| 4000 | any | **Deny** |

The jumpbox NSG mirrors the denial on egress, so a mistake in either rule
alone does not silently reopen the bypass.

> **Limit.** DNS is **not** a boundary — a developer can supply the hostname
> and address manually. The NSG rules are the control.

> **Limit.** Bastion's own endpoint is public. "Private" describes the
> *inference data plane*, not every management surface.

### Bootstrap ordering

APIM cannot be created with public access already disabled. The sequence is:
create with **no usable inference API** and a deny-all policy → create the
private endpoint → disable public access → attach the working API. No usable
inference endpoint is ever publicly exposed.

Public-access closure has exactly **one owner** (an `azapi_update_resource`;
the AzureRM resource ignores the property), so repeated applies cannot reopen
it.

## Data handling

### Never logged, at any verbosity

Authorization headers, bearer tokens, prompt text, source code, model output,
tool arguments, file contents, UPNs, email addresses, display names, raw
`LastError.Message`, backend bodies, backend URLs, resource IDs, policy source.

Enforced by zero body bytes on **all four** diagnostic legs, a header
allowlist, fixed trace messages with structured metadata, and Foundry
diagnostics limited to `Audit` + `AzureOpenAIRequestUsage`.

> **Limit.** A category name does not establish that its contents are
> payload-free. `allLogs` is never enabled and `RequestResponse`/`Trace` are
> explicitly excluded, but enabling further categories requires schema review
> first (gate G10).

### Recorded identifiers

`tid` and `oid` are **protected pseudonymous identifiers** — in
access-controlled logs, never metric dimensions, never UPNs. Resolving an
object ID to a person requires a separate Entra lookup, which is intended
friction.

### Client-side data

The VS Code extension sends only what the user explicitly selects. It never
reads the workspace on its own, applies edits, or executes suggested code.

> **Limit.** On the private jumpbox, anything opened in VS Code persists on
> that VM's disk. Treat the jumpbox as holding the same data classification as
> a workstation.

## Secrets

There are none at runtime. Local key authentication is disabled on the Foundry
account **at creation**, the API requires no subscription, and the built-in
all-access APIM subscription is suspended.

### Terraform state contract

**No reusable authentication secret** in state, plans, outputs, or logs.

| Resource | Handling |
| --- | --- |
| Log Analytics | **AzAPI** — AzureRM reads workspace shared keys into state |
| APIM subscription | **No resource declared**; built-in one suspended via AzAPI without `ListSecrets` |
| Foundry account | AzureRM skips `AccountsListKeys` when local auth is disabled at creation |
| App Insights | Connection string is a **sensitive module output**, never a root output |
| Jumpbox password | **Ephemeral** `random_password` + AzAPI **write-only** `sensitive_body` — never in state on either side |

> **Limit.** An App Insights instrumentation key is documented by Microsoft as
> an *identifier, not a security token*. Local auth is disabled, so the
> connection string alone cannot ingest. These are classified as telemetry
> identifiers under the agreed contract — a reviewer who requires zero
> key-*named* fields in state should read that classification and decide.

> **Limit.** Terraform `sensitive` redacts display only; it does **not** remove
> values from state. Protect state files, plans, backups, and `.azure`
> directories regardless.

> **Limit.** azd converts Terraform outputs **without preserving the Sensitive
> flag**, so an exported secret would land in the azd environment file in
> cleartext. Root outputs are identifiers, endpoints, and configuration only.

## Transport

HTTPS enforced at the gateway; clients refuse a non-HTTPS endpoint before
attaching a token. HSTS and `X-Content-Type-Options` are set on responses.

> **Limit.** APIM **v2 tiers do not expose the classic cipher-configuration
> surface**. No `security` block is declared, because declaring unsupported
> knobs produces either an error or silent drift. TLS posture is whatever the
> v2 platform provides.

## Unresolved

| Gate | Issue |
| --- | --- |
| **G4** | Windows jumpbox cannot satisfy GA-only + passwordless + no-secret-in-state simultaneously. Fails closed behind `acknowledge_unresolved_g4`. |
| G1 | Token audience must be observed in a real token, not copied from docs |
| G5 | Whether daily-quota 403 is distinguishable from RBAC 403 |
| G6 | Downstream correlation ends at the gateway |
| G7 | Behavior with chunked/compressed/missing-length bodies |
| G8 | Anti-bypass denial is unproven against a live deployment |
| G9 | Field-level state inspection not yet performed |
| G10 | Whether `Audit`/`AzureOpenAIRequestUsage` contents are payload-free |

Full detail in [`platform-validation.md`](platform-validation.md).

## Reporting

See [`SECURITY.md`](../SECURITY.md).
