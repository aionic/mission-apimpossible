# Platform validation

What this sample's claims rest on, and what they do not.

Every material platform behaviour is recorded with an evidence class, because
"the documentation says so" and "we ran it and watched" are different kinds of
confidence and should not be presented as one.

| Class | Meaning |
| --- | --- |
| **Empirical** | Run against real Azure resources and observed. |
| **Documented** | Stated in current first-party Microsoft or HashiCorp documentation. |
| **Source-observed** | Read from shipped product or provider source. Indicates the behaviour of a specific build, not a support contract. |
| **Unresolved** | Contradictory, undocumented, or unproven. Not implemented as if it were fact. |

Both patterns have been deployed, verified and destroyed. The public pattern
ran for roughly two days on `gpt-5.3-codex` (2026-02-24) in `eastus2`; the
private pattern was deployed to a separate resource group and torn down after
verification.

---

## Status

| Gate | Subject | State |
| --- | --- | --- |
| **G1** | Token audience and claims | ✅ Empirical |
| **G2** | Caller is a delegated human | ✅ Empirical |
| **G3** | VS Code authentication | 🟡 Partly — static half verified, interactive flow needs a person |
| **G4** | Windows jumpbox access | ❌ **Unresolved by design.** Fails closed |
| **G5** | Token governance | ✅ Empirical, with a significant limit — see below |
| **G6** | Correlation and SSE | ✅ Empirical, boundary documented |
| **G7** | Request validation ceilings | ✅ Empirical |
| **G8** | Private networking | 🟡 Proven *closed*, not proven *usable* — blocked by G4 |
| **G9** | Terraform state contents | ✅ Empirical |
| **G10** | Payload-free telemetry | ✅ Empirical |
| **G11** | Deployment target and lifecycle | ✅ Empirical |

Everything marked Empirical has a script that reproduces it. They are listed
per gate.

---

## G1 — Token audience and claims

**Empirical.** The audience a token actually carries is not the scope string
you request. Requesting `<resource>/.default` yields a token whose `aud` is
`<resource>`, without the suffix. The gateway pins the measured value.

Observed on a delegated user token: `ver: 1.0` (so the client appears as
`appid`, not `azp`), `scp: user_impersonation`, `idtyp: user`, and **no `roles`
claim** — which is why rejecting on the presence of `roles` would be wrong.

**The audience is now a dedicated application, not the Foundry resource.** That
change was forced by a security finding; see G2.

Reproduce: `docs/deployment.md`, step 2b.

---

## G2 — The caller is a delegated human, and is authorised

**Empirical.** `validate-azure-ad-token` pins a literal tenant GUID. `tid` and
`oid` alone do not distinguish a person from a service principal; the
discriminators are that `scp` is issued only on delegated tokens and that
`idtyp = "app"` marks an app-only token.

**Authentication is not authorisation, and conflating them was a real
vulnerability here.**

Using the Foundry resource as the audience looked correct and was not. It is a
Microsoft **first-party** resource, and Entra issues tokens for those to any
authenticated principal — issuance is not gated by RBAC on the model. In
`brokered` mode the gateway calls the model with its own managed identity, so
every member and B2B guest of the tenant could obtain inference they held no
permission for. The client-application allowlist did not help: it filters
**applications**, and the ones it held — Azure CLI, VS Code — are public
first-party clients every tenant user already has.

Fixed with two independent layers:

| Layer | Control | Evidence |
| --- | --- | --- |
| Microsoft Entra | Dedicated application with `appRoleAssignmentRequired` | An unassigned user cannot obtain a token at all |
| Gateway policy | `scp` must contain the required scope, matched as a whole entry | Old audience → `401`; gateway audience, assigned user → `200` |

A Terraform precondition refuses `identity_mode = "brokered"` with an empty
`required_scope`. The original gap was not a typo — it was a plausible
configuration nobody flagged, and configuration that plausible needs a machine
to object.

> `passthrough` mode never had this problem: the caller's own token reaches
> Foundry, which performs its own RBAC check. Brokered mode removes that second
> decision in exchange for eliminating the direct-backend bypass, so it must
> supply an equivalent check of its own.

See [threat model T19](threat-model.md). Reproduce:
`scripts/create-gateway-app.ps1`, then request a token for the old audience and
confirm `401`.

---

## G3 — VS Code authentication

**Source-observed, in the shipped bundle.** The built-in `microsoft` provider
parses pseudo-scopes: `VSCODE_TENANT:<guid>` selects the authority and
`VSCODE_CLIENT_ID:<guid>` the client. Every `VSCODE_`-prefixed entry is
filtered out before the token request, so none reaches Entra as a requested
permission.

Confirmed in the shipped `microsoft-authentication` bundle of the build in use
(Insiders 1.137, commit `f44f55cde0`) rather than from a branch on GitHub —
`getTenant()` and `getScopesToSend()`.

**Still not documented API.** A bundle can change in any update, so the
extension fails loudly if a tenant-pinned request fails rather than falling
back to another authority or a non-human credential.

**Pending:** interactive sign-in, consent, refresh, sign-out and cancellation
need a person at a keyboard. The token path itself is proven — the local proxy
uses the same gateway from Copilot daily.

---

## G4 — Windows jumpbox access (unresolved)

**Unresolved, by design.** Three options exist and each conflicts with a rule
this sample holds itself to:

| Option | Conflict |
| --- | --- |
| Bastion portal Entra RDP | Public **preview** |
| Native-client Entra RDP | Prompts for a password |
| `azurerm_windows_virtual_machine` | Stores the administrator password **in Terraform state** |

The module fails closed behind `acknowledge_unresolved_g4`. It is not enabled
by default and is not claimed to work.

A pinned AzAPI VM with an ephemeral bootstrap password and write-only
`sensitive_body` may resolve it, but that has not been proven and is not
shipped.

---

## G5 — Token governance

**Empirical, and the result matters more than a pass mark.**

Reproduce: `scripts/verify-token-governance.ps1`.

Two limits apply to the same caller and both surface as HTTP 429, so counting
429s tells you nothing. They are distinguishable: `llm-token-limit` sets
`x-ratelimit-remaining-tokens` on its rejections, `rate-limit-by-key` does not.

**Only `rate-limit-by-key` constrains a burst.** Ten requests dispatched inside
57 ms produced five `200`s and five `429`s — all five from `rate-limit-by-key`,
none from `llm-token-limit`.

**`llm-token-limit` cannot reject a concurrent request.** With
`estimate-prompt-tokens="false"` it has no token count until the response
returns, so it cannot pre-charge. Every caller in a ten-way burst cleared the
check against a counter nothing had incremented, and each saw only its own
~1,600 tokens. Roughly 16,000 tokens crossed a 20,000 ceiling with no caller
aware of the others.

**The documented per-gateway overshoot is measurable.** `calls="2"` admitted
**five** simultaneous requests, because counters are per gateway node. The
effective ceiling is `calls × node count`, and node count is not something this
sample controls or can pin.

**Sequential load never throttles, and that is correct.** Twenty-four
consecutive requests of ~1,200 tokens against a 20,000 TPM ceiling left
`remaining` oscillating between 17,430 and 18,939 — at ~15s per request, tokens
age out of the sliding minute as fast as one caller consumes them.

Consequences, stated plainly:

- The concurrency guard is `rate-limit-by-key`. It is coarse and it overshoots.
- `llm-token-limit` is an **after-the-fact** ceiling. It restrains a sustained
  caller; it does not bound an instantaneous burst.
- Neither is a billing control. Azure Cost Management is the financial source
  of truth.

**Unresolved:** whether daily-quota exhaustion (documented as `403`) can be
reliably distinguished from an authorisation `403`. Until it can, the gateway
does not normalise it to `429`.

---

## G6 — Correlation and SSE

**Empirical.** The chain that can be claimed is
`client → APIM request → APIM backend dependency → captured Foundry request ID`.
It joins end to end, and streaming works with both token policies enabled.

**Documented.** Foundry returns `apim-request-id`, described as *"a request ID
used for troubleshooting purposes"*.

**Unresolved, and therefore not claimed.** No first-party source establishes
that `x-ms-client-request-id` is echoed, persisted or queryable, or that
Foundry exposes internal W3C spans to the caller. The Foundry request ID is a
support handle for raising a case, not a joinable trace segment.

Final usage may be missing on a streamed response. Missing usage is recorded as
unknown, never as zero.

---

## G7 — Request validation ceilings

**Empirical.** Reproduce: `scripts/verify-request-validation.ps1` and
`scripts/probe-size-ceiling.ps1`.

Fourteen hostile request shapes all fail closed — oversize bodies, chunked
framing with no `Content-Length`, gzip, malformed UTF-8, duplicate JSON keys,
200-level nesting, truncated JSON, unknown fields, hosted tools, and a
`text/plain` content type. A `500` counts as a failure here even when the
request is garbage, and so does a `200`.

The suite carries a **positive control** — one valid request that must return
`200`. Without it the whole suite would pass against a gateway that rejects
everything.

**The size limits are measured, not chosen.** The documented ceilings
contradict each other: `validate-content` permits 4 MB, the gateway runtime
table lists 100 KiB for validated bodies, and v2 has a separate 2 MiB buffered
limit. The original answer was to pick the smallest, 64 KiB.

That proved unusable. A single GitHub Copilot agent turn carries ~138 KB of
input across 8–10 items with 88–90 tool definitions, the largest description
5,859 characters. Probing the deployed gateway passes **512 KiB** comfortably,
so the 100 KiB figure does not govern this path.

| Bound | Value | Basis |
| --- | --- | --- |
| Request body | 1 MiB | 512 KiB proven to pass |
| `input` text | 768 KiB | ~138 KB measured per turn |
| Message items | 400 | 8–10 measured |
| Tools | 128 | 88–90 measured |
| Tool description | 32 KiB | 5,859 characters measured |

Raising a bound because reality needed it is not the same as removing it; tests
assert each still rejects.

---

## G8 — Private networking

**Empirical for what it prevents. Unproven for what it enables.**

Deployed to a separate resource group in an isolated Terraform workspace,
verified, and destroyed.

| Control | Observed |
| --- | --- |
| APIM `publicNetworkAccess` | `Disabled`, with outbound VNet integration |
| Foundry `publicNetworkAccess` | `Disabled` |
| Foundry `networkAcls` | `defaultAction: Deny`, `bypass: None` |
| Private endpoints | Both `Approved` |
| Repeat `terraform apply` | `No changes`; both endpoints still `Disabled` |

Anti-bypass rules on the model's private-endpoint subnet, in priority order:

| Priority | Rule |
| --- | --- |
| 100 | Allow the APIM integration subnet, port 443 |
| 200 | **Deny the jumpbox subnet**, all ports |
| 4000 | Deny everything else |

Both sit ahead of the default `AllowVNetInBound`.

**The authorised-human test needed a second attempt to mean anything.** Calling
Foundry directly returned `401`, which looks like a pass and is not: in
brokered mode no human holds inference RBAC, so that `401` cannot distinguish a
network block from an RBAC block. Granting the test identity
`Cognitive Services OpenAI User` and retrying settles it — the specific
dataAction complaint disappears, confirming RBAC took effect, and access is
still denied.

> **Operational warning.** Foundry reports a **network** denial as an
> authorisation-shaped `401` that never mentions the network, while APIM states
> the reason plainly. When a private-pattern call fails, check
> `publicNetworkAccess` and the effective NSG rules *before* touching role
> assignments.

**Not claimed:** that a developer inside the VNet succeeds through the gateway.
That needs the jumpbox, which G4 blocks. The private pattern is verified as
*closed*, not as *usable*.

---

## G9 — Terraform state contents

**Empirical.** Reproduce: `scripts/audit-state-secrets.ps1`.

23 resources audited field by field. **Zero violations.** Every match was a
permitted non-credential: the Application Insights connection string and
instrumentation key (telemetry identifiers, classified explicitly), and
`certificate_source: "BuiltIn"` — an enum, whose sibling `certificate` and
`certificate_password` fields are empty, which is what actually matters.

The avoidance choices are confirmed **by absence**:

| Expected risk | Outcome |
| --- | --- |
| `azurerm_log_analytics_workspace` reads shared keys | Resource not present — the workspace is an `azapi_resource` exporting only `properties.customerId` |
| `azurerm_api_management_subscription` calls `ListSecrets` | Not declared — the built-in subscription is disabled via `azapi_resource_action`, which never reads keys |
| Windows VM stores its admin password | Not present in the public profile; remains the open question in G4 |

The auditor also refuses any tracked `*.tfplan`, `tfplan.binary` or
`*.tfstate.backup` — a saved plan is state under another name.

> Terraform `sensitive` redacts *display* only. It does not remove values from
> state. Protect state files, plans, backups and `.azure` directories
> regardless.

---

## G10 — Telemetry that cannot leak payloads

**Empirical.** All four APIM body-capture legs are disabled, only approved
metadata headers are recorded, and `allLogs`, `RequestResponse` and unreviewed
`Trace` categories are off.

Canary phrases from real sessions were absent from `traces`, `requests`,
`dependencies`, `exceptions` and `customEvents` — **with 44 records in the same
window**, because an empty search result proves nothing if ingestion is broken.
Both are checked together.

`tid` and `oid` appear in access-controlled logs as pseudonymous identifiers.
Neither is ever a metric dimension: custom metrics cap at 5 dimensions and
1,000 active series, and exceeding those **silently discards** data.

> `store: false` disables Responses storage. It is **not** a claim that
> service-side abuse-monitoring retention is disabled; that is governed by your
> agreement with Microsoft.

---

## G11 — Deployment target and lifecycle

**Empirical.** Both patterns deployed, verified and destroyed independently.

| | Public | Private |
| --- | --- | --- |
| Fresh apply | 41 resources | 64 resources |
| Repeat apply | no changes | `No changes`, access still `Disabled` |
| Destroy | 41 destroyed | 33 destroyed |
| Soft-deleted remnants | none | none |

`azd`'s Terraform integration is documented as beta. That was accepted as a
tooling risk; the Azure runtime features this stack uses are GA.

---

## Platform constraints found by deploying

Each of these passed every offline check — `terraform validate`, policy XML
well-formedness, the full unit suite — and still broke the gateway. They are
recorded because each is a reusable APIM constraint, not a bug in this
repository.

| # | Constraint | Symptom if violated |
| --- | --- | --- |
| **D1** | `<trace>` metadata values must be non-empty at creation **and** runtime | A literal `value=""` makes APIM accept the fragment and never create it, reported as a misleading `404`. An expression *evaluating* to empty throws at runtime as a blanket `500` with no telemetry. All nullable fields coalesce to `"none"`. |
| **D2** | `schema-id` resolves a **service-level** schema | `azurerm_api_management_api_schema` creates one `validate-content` cannot resolve at any scope. Use `azurerm_api_management_global_schema`. |
| **D3** | A policy fragment cannot contain `<include-fragment>` | Silently dropped. Policies may include fragments; only nesting inside a fragment is rejected. |
| **D4** | Global scope forbids `<base/>`, and an empty `<backend/>` means *never forward* | A `500` that looks like a backend fault. APIM's own default global policy carries an explicit `<forward-request />`. |
| **D5** | The Application Insights logger needs `identity_client_id` when local auth is disabled | Ingestion is refused and every `<trace>` throws. |
| **D6** | `validate-content` needs a declared request representation | Every request is rejected with `Unspecified content type application/json is not allowed`. |
| **D7** | Policy expressions may use only APIM's allowed .NET types | A violation fails **asynchronously and silently**: the ARM `PUT` returns `200`, provisioning moves to `Failed` with no error message anywhere, and Terraform reports only `polling failed`. `UTF8Encoding` is not allowed; `System.Text.Encoding` is. |
| **D8** | Application Insights auto-creates a `Failure Anomalies` alert rule | No Terraform resource declares it and no flag prevents it, so `destroy` removes everything it owns and then fails on the resource group without naming the culprit. Handled by `scripts/predown.ps1` as an azd `predown` hook. |

**Methodology note.** APIM policy propagation is **not** instant. Four-second
waits measured stale policy and produced contradictory bisection results that
sent diagnosis down two dead ends. Allow **45 seconds** between a policy write
and a test request.

**Diagnostic note.** The gateway returns a sanitised `invalid_request` that
deliberately does not name the failing field — correct for production, useless
at a keyboard. When a client is rejected for reasons that are not obvious,
capture the body locally with `map_proxy --capture-text` and validate it
against the schema offline. That turned three rounds of guesswork into one
precise answer, and it is why capture mode is kept rather than removed.

---

## What is still unproven

Stated here rather than left implicit.

| Item | Status |
| --- | --- |
| Passwordless Windows jumpbox access | **G4 — unresolved.** Fails closed |
| A developer inside the VNet succeeding through the private gateway | Blocked by G4 |
| Daily-quota `403` distinguishable from an authorisation `403` | Unresolved; normalisation to `429` stays off |
| `x-ms-client-request-id` observable downstream of the gateway | Unresolved; not claimed |
| VS Code interactive sign-in, consent, refresh, sign-out, cancel | Needs a person at a keyboard |
| Exact streamed token accounting | Approximate by design; prompt tokens are always estimated when streaming |
