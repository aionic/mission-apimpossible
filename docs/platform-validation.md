# Platform validation ledger

Every material platform claim this repository depends on is recorded here with
its evidence class. The classes are deliberately distinct:

| Class | Meaning |
| --- | --- |
| **Documented** | Stated in current first-party Microsoft or HashiCorp documentation. |
| **Source-observed** | Read from provider or product source. Indicates likely behavior of a specific version; not a support contract. |
| **Empirical** | Proven by running it against real Azure resources and recorded with the date and resource versions. |
| **Unresolved** | Contradictory, undocumented, or not yet proven. Must not be implemented as if it were fact. |

> **Nothing in this file is Empirical yet.** No Azure resource has been created
> by this repository. Every row marked *Pending* requires a live run before the
> corresponding acceptance criterion in
> the acceptance criteria may be marked satisfied.
>
> **UPDATE 2026-09-14:** the public pattern has now been deployed and verified.
> See "Deployment findings" below and the per-gate updates. The private
> pattern remains undeployed.

> **Gates G1–G6 and G9–G11 now carry EMPIRICAL evidence** from a live public
> deployment on **2026-09-14** (subscription `05322c41…`, region `eastus2`,
> model `gpt-5.3-codex` 2026-02-24). Rows still marked *Pending* are private-
> pattern gates (G7 partially, G8) that require the private deployment.

Documentation was reviewed on **2026-09-14**. Re-verify volatile rows against the
versions pinned in [`deployment.md`](deployment.md) before deployment.

---

## Deployment findings — things only a real deployment revealed

Six defects passed every offline check (`terraform validate`, policy XML
well-formedness, 97 unit tests) and still broke the gateway completely. They
are recorded here because each is a genuine, reusable APIM constraint.

### D1 — Trace metadata values must be non-empty, at creation *and* runtime

The single most expensive finding, because it fails silently in two different
ways:

| When | Symptom |
| --- | --- |
| Fragment creation | A literal `value=""` makes APIM **accept the PUT and never create the fragment**. Terraform reports `404 PolicyFragment not found` while polling — indistinguishable from a race condition. |
| Request runtime | An expression that **evaluates** to `""` makes the `trace` throw, surfacing as a blanket **HTTP 500** — with no telemetry to diagnose it, because telemetry is the broken thing. |

`failure_category` is empty on every *successful* request, so this fired on the
happy path. All nullable fields now coalesce to the literal `"none"`,
documented in [`telemetry.schema.json`](../specs/telemetry.schema.json) as the
absent marker.

### D2 — `schema-id` resolves a **service-level** schema, not an API-level one

The `validate-content` reference says "a schema that was added to the API
Management **instance**" and means it literally.
`azurerm_api_management_api_schema` creates `/apis/{id}/schemas/{id}`, which
`validate-content` cannot resolve **at any policy scope** — it fails with
`The schema responses-request does not exist` while the schema is plainly
visible on the API. The correct resource is
`azurerm_api_management_global_schema`.

### D3 — A policy fragment cannot contain `<include-fragment>`

Same silent-drop symptom as D1. Verified by controlled experiment: a trivial
fragment created fine; an otherwise-identical one containing a single
`<include-fragment>` returned success on PUT and 404 on the follow-up GET.
Policies can include fragments; only nesting inside a fragment is rejected.

### D4 — Global scope has no `<base/>`, and an empty `<backend/>` never forwards

`<base/>` is rejected at global scope (`Element <base/> is not allowed in
global context`) because there is no parent to inherit from. But simply
removing it leaves an empty `<backend/>`, which means *never forward* — every
request then fails with a 500 that looks like a backend fault. APIM's own
default global policy contains an explicit `<forward-request />`.

### D5 — The Application Insights logger needs `identity_client_id`

With local authentication disabled on the component (the posture this
repository argues for), the logger must be told to use the gateway's managed
identity via `identity_client_id = "SystemAssigned"`. Otherwise APIM attempts
connection-string ingestion, is refused, and every `trace` throws.

### D6 — `validate-content` needs a declared request representation

Any content type absent from the API definition is treated as *unspecified*.
Without a `request { representation { content_type = "application/json" } }`
block on the operation, the policy rejects every request with
`Unspecified content type application/json is not allowed`.

### D7 — Policy expressions may only use APIM's allowed .NET types, and a violation fails **asynchronously and silently**

Strict UTF-8 validation naturally wants
`new System.Text.UTF8Encoding(false, true)`, whose decoder throws on invalid
bytes instead of substituting. `UTF8Encoding` is **not** in APIM's allowed
policy-expression type list; only `System.Text.Encoding` is.

The failure mode is the problem. The ARM `PUT` returns **HTTP 200** with
`ProvisioningState: InProgress`, and the fragment then moves to
`ProvisioningState: Failed` — carrying **no error message, anywhere**.
Terraform surfaces only `polling after CreateOrUpdate: polling failed`, which
names neither the expression nor the type. Nothing in the portal, the activity
log, or the resource body says which construct was rejected.

Diagnosis requires `PUT`ing the fragment directly and polling the resource,
then bisecting the expression by hand.

The working form round-trips the bytes using only permitted types:

```csharp
var bytes = context.Request.Body.As<byte[]>(preserveContent: true);
var text  = System.Text.Encoding.UTF8.GetString(bytes);
var round = System.Text.Encoding.UTF8.GetBytes(text);
// valid UTF-8 round-trips byte-for-byte; invalid bytes become U+FFFD and differ
```

This is exact rather than heuristic, and a body that legitimately contains
U+FFFD still round-trips cleanly, so there is no false rejection.

**Rule: any new type referenced in a policy expression must be checked against
the allowed list before use.** An offline XML check cannot catch this, because
the XML is perfectly well-formed.

### D8 — Teardown fails on a resource Azure created for you

Application Insights automatically provisions a Smart Detector alert rule named
`Failure Anomalies - <app-insights-name>`. No Terraform resource declares it,
and no provider flag prevents it.

`terraform destroy` therefore removes all 33 resources it owns, then fails on
the final step:

```text
Error: deleting Resource Group "rg-...": the Resource Group still contains Resources.
```

The message never names the offending resource, so the obvious next move is to
go hunting in the portal. `az resource list -g <rg>` returns exactly one row.

Handled by `scripts/predown.ps1`, wired as an azd `predown` hook so it runs
*before* the confusing failure rather than after it. The script only deletes
rules whose name begins with `Failure Anomalies - `, and only in the named
resource group; anything else is reported and left alone.

Verified afterwards: the resource group is gone, and neither APIM nor Foundry
left a soft-deleted service behind to block name reuse.

### Methodology note: policy propagation is not instant

Several intermediate bisection results in this investigation were **wrong**
because 4-second waits measured stale policy, producing contradictory readings
that sent the diagnosis down two dead ends. All conclusions above were
re-derived with 45-second waits between a policy write and the test request.
Any future policy experiment must do the same.

---

## G1 — Responses endpoint, scope, and token audience

**Documented.** The v1 API is reached at
`https://<resource>.openai.azure.com/openai/v1/responses` and removes the
`api-version` query parameter. Microsoft Entra examples across Python, C#,
JavaScript, Go, and Java consistently use the scope
`https://ai.azure.com/.default`, and the v1 client refreshes bearer tokens
through a callable rather than a static key.
([v1 API lifecycle](https://learn.microsoft.com/azure/foundry/openai/api-version-lifecycle),
[Responses how-to](https://learn.microsoft.com/azure/foundry/openai/how-to/responses))

**Unresolved.** The REST reference for Responses has at times described the
`https://cognitiveservices.azure.com/.default` scope while the language guides
use `https://ai.azure.com/.default`. A `.default` *scope string* is not the
`aud` claim of the issued token, and APIM validates `aud`.

**Gate.** Acquire a real token with the configured scope from both official VS
Code and Azure CLI, decode only the non-sensitive header/claims locally, and pin
the observed `aud` into the APIM policy. Do not configure multiple accepted
audiences to make the gate pass.

| Check | Status |
| --- | --- |
| Endpoint path and no `api-version` requirement | Documented + **Empirical** |
| Scope string used by first-party SDK samples | Documented |
| Actual `aud` claim issued for that scope | **EMPIRICAL — `https://ai.azure.com`** |
| Same `aud` from VS Code and Azure CLI | Azure CLI **Empirical**; VS Code pending |

> **Confirmed by measurement, and it matters.** A token acquired with scope
> `https://ai.azure.com/.default` carries `aud = https://ai.azure.com` — the
> scope has a `/.default` suffix, the audience does **not**. Pinning the scope
> string as the APIM audience would 401 every request.

---

## G2 — Proving the caller is a delegated human

**Documented.** `validate-azure-ad-token` validates signature, expiry, issuer,
tenant, and audience, and can publish the validated token to a policy variable.
([policy reference](https://learn.microsoft.com/azure/api-management/validate-azure-ad-token-policy))

**Documented.** `tid` and `oid` do **not** distinguish a human from a service
principal — service principals have both. The `scp` claim is present only on
delegated user tokens; `idtyp=app` marks an app-only token when present.
Client application identity appears as `appid` on v1.0 tokens and `azp` on
v2.0 tokens.
([claims validation](https://learn.microsoft.com/entra/identity-platform/claims-validation),
[claims reference](https://learn.microsoft.com/entra/identity-platform/access-token-claims-reference))

**Design consequence.** Authorization requires *all* of: successful validation,
a delegated scope, a single-valued `tid` and `oid`, and an allowlisted client
application. Presence of a `roles` claim alone must **not** reject the call —
humans can hold app roles. Reject app-only tokens specifically.

| Check | Status |
| --- | --- |
| Fixed-tenant validation with validated-token output | Documented + **Empirical** |
| `scp` present only on delegated tokens | Documented |
| Observed claim set for the VS Code client and Azure CLI client | **EMPIRICAL for Azure CLI** |

Observed Azure CLI token claims, which validate the whole
delegated-human design:

| Claim | Value | Consequence |
| --- | --- | --- |
| `ver` | `1.0` | Client appears as `appid`, **not** `azp` — the policy's fallback is required, not defensive |
| `appid` | `04b07795-8ddb-461a-bbee-02f9e1bf7b46` | Azure CLI |
| `scp` | `user_impersonation` | Delegated user token ✓ |
| `idtyp` | `user` | Not app-only ✓ |
| `roles` | *absent* | Confirms rejecting on `roles` would have been wrong |

---

## G3 — Official VS Code user authentication

**Documented.** `vscode.authentication.getSession(providerId, scopes, options)`
is public extension API with `createIfNone`, `forceNewSession`, and `silent`
forms, plus `onDidChangeSessions`.
([VS Code API](https://code.visualstudio.com/api/references/vscode-api#authentication))

**Source-observed.** The built-in `microsoft` provider parses pseudo-scopes to
select a tenant and client: `VSCODE_TENANT:<guid>` overrides the default
`organizations` authority, and `VSCODE_CLIENT_ID:<guid>` overrides the default
client. Scopes prefixed `VSCODE_` are stripped before the token request.
([`scopeData.ts`](https://github.com/microsoft/vscode/blob/main/extensions/microsoft-authentication/src/common/scopeData.ts))

**Source-observed.** The provider's redirect handling accepts a fixed set of
hosts and URI schemes. Forks that do not match are not guaranteed to complete
the flow.
([`env.ts`](https://github.com/microsoft/vscode/blob/main/extensions/microsoft-authentication/src/common/env.ts))

> `VSCODE_TENANT:` is **source-observed, not documented extension API**. The
> extension must therefore degrade safely: if a tenant-pinned request fails,
> surface a clear error naming the tenant, rather than silently falling back to
> a different authority or to a non-human credential.

### Verified against the shipped bundle

The claims above were originally read from `main` on GitHub, which is not
necessarily what any given installation runs. They have now been confirmed in
the **shipped** `microsoft-authentication` bundle of the exact build in use
(VS Code Insiders 1.137, commit `f44f55cde0`):

```js
getTenant(e, r) {
  if (r?.path) { let n = r.path.split("/")[1]; if (n) return n }
  return e.reduce((n, i) => i.startsWith("VSCODE_TENANT:")
    ? i.split("VSCODE_TENANT:")[1] : n, void 0) ?? x$
}

getScopesToSend(e) {
  let r = e.filter(i => !i.startsWith("VSCODE_"));   // stripped before the request
  ...
}
```

Both behaviours hold: `VSCODE_TENANT:<guid>` selects the authority, and every
`VSCODE_`-prefixed entry is filtered out before the token request, so it never
reaches Entra as a requested permission. A `VSCODE_CLIENT_ID:` sibling exists
in the same reducer.

This raises the evidence from "source-observed on a branch" to "verified in the
binary being run". It does **not** make it documented API - the guidance above
still stands, because a bundle can change in any update without notice.

| Check | Status |
| --- | --- |
| `getSession` availability and options | Documented |
| Tenant pinning via `VSCODE_TENANT:` | **Verified in the shipped bundle** (still not documented API) |
| `VSCODE_*` scopes stripped before the token request | **Verified in the shipped bundle** |
| Host compatibility constraints for forks | Source-observed |
| Real interactive sign-in, consent, refresh, sign-out, cancel | **Pending — needs a human at the keyboard** |

---

## G4 — Windows jumpbox access (**UNRESOLVED — blocks `map-p07` completion**)

This is the one gate that is known to conflict with an agreed requirement.

**Documented.** Microsoft Entra ID authentication for **RDP connections in the
portal is in public preview**; Entra for SSH in the portal is GA. Portal
connections are passwordless. Native-client RDP with `--enable-mfa` requires
Bastion **Standard** SKU or higher and **prompts for a password after MFA**.
Native-client RDP additionally requires the connecting PC to be Entra
registered/joined/hybrid-joined to the same directory.
([Bastion Entra authentication](https://learn.microsoft.com/azure/bastion/bastion-entra-id-authentication))

**Documented.** `azurerm_windows_virtual_machine` states plainly that *"all
arguments including the administrator login and password will be stored in the
raw state as plain-text."*
([resource docs](https://github.com/hashicorp/terraform-provider-azurerm/blob/v5.5.0/website/docs/r/windows_virtual_machine.html.markdown))

**Documented.** `azapi_resource` exposes `sensitive_body` as a **write-only**
argument (requires Terraform 1.11+) and allows explicit control of exported
response values.
([azapi resource](https://github.com/Azure/terraform-provider-azapi/blob/main/docs/resources/resource.md))

**Caught during scaffolding.** A plain `random_password` *resource* persists
its generated value in Terraform state, which would have defeated the
write-only `sensitive_body` entirely — the credential would simply have leaked
in on the other side. This was confirmed by running `terraform plan`, which
listed `random_password.bootstrap` as a resource to be created with a
state-persisted `result`.

The module now uses an **`ephemeral "random_password"`** block (Terraform
1.10+, random provider 3.7+). Ephemeral values are never written to state.
`terraform plan` now shows the resource being *opened* rather than *created*,
and no password-bearing resource appears in the planned set.

`sensitive_body_version` is pinned so the regenerated ephemeral value does not
churn the VM on every plan.

### The conflict

| Requirement | Conflicting fact |
| --- | --- |
| GA-only runtime features | Portal passwordless Entra RDP is **preview** |
| Passwordless sign-in | Native-client Entra RDP **prompts for a password** |
| No reusable authentication secret in state | AzureRM Windows VM **stores the admin password in state** |

### Options, none yet approved

1. **AzAPI VM with write-only ephemeral bootstrap password.** Satisfies the
   state contract if proven. Requires testing create, refresh, repeated apply,
   and recreate; and disabling the bootstrap account once Entra login is
   healthy. Must prove a separately authorized recovery path exists.
2. **Accept preview portal RDP** for the sample only, documented as an explicit
   exception. Requires approval; contradicts the GA-only decision.
3. **Linux jumpbox** with GA Entra SSH. Satisfies GA and passwordless cleanly
   but was explicitly declined because the tester wants to run VS Code
   natively on the jumpbox.

**Current state.** `map-p07` implements the networking and the
`enable_test_access` toggle, and prepares the VM module, but the repository
must not claim complete private Windows testing until option 1 is proven or
another option is approved. See [`docs/deployment.md`](deployment.md).

---

## G5 — Token governance policies against Responses

**Documented.** Current references for `llm-token-limit` and
`llm-emit-token-metric` state they apply to *"OpenAI Chat Completions or
Responses API"*, describe streaming behavior, and place **both policies in
`inbound`**.
([llm-token-limit](https://learn.microsoft.com/azure/api-management/llm-token-limit-policy),
[llm-emit-token-metric](https://learn.microsoft.com/azure/api-management/llm-emit-token-metric-policy))

**Documented limits that must not be overstated:**

- TPM exhaustion returns **429**; daily quota exhaustion returns **403**.
- `Daily` is a **fixed UTC-day** window, not rolling 24 hours.
- Counters are per gateway; concurrent requests can overshoot.
- Remaining-quota headers are explicitly an **estimate**.
- For streaming, prompt tokens are **always estimated** regardless of
  `estimate-prompt-tokens`.
- Custom metrics allow 5 dimensions, 100 values per dimension, 1,000 active
  series per namespace; exceeding limits **silently discards** data.

**Design consequence.** Quotas are safeguards, not billing controls, and
`oid` must never become a metric dimension. Per-user detail belongs in logs.

| Check | Status |
| --- | --- |
| Responses and streaming support, inbound placement | Documented |
| 429 vs 403 split and UTC-day window | Documented |
| Policy accepted on Standard v2 with our attribute set | **Empirical — accepted, enforcing** |
| Which policy actually constrains concurrency | **Empirical — see below** |
| Accounting headers present on every success | **Empirical — 34/34 responses** |
| `Retry-After` present on every rejection | **Empirical — 5/5 rejections** |
| Daily-quota 403 reliably distinguishable from RBAC 403 | **Pending — gates the approved 429 normalization** |
| Per-user counter isolation across refreshed tokens | **Pending — needs a second test identity** |

### Empirical: only `rate-limit-by-key` constrains concurrency

Reproduce with `scripts/verify-token-governance.ps1`.

Two limits apply to the same caller and both surface as HTTP 429, so a test
that merely counts 429s cannot tell you which one fired. They are
distinguishable at runtime: `llm-token-limit` sets
`x-ratelimit-remaining-tokens` on its rejections, `rate-limit-by-key` does not.

**Sequential load never throttles, and that is correct.** 24 consecutive
requests, ~1,200 tokens each, against a 20,000 TPM ceiling: `remaining`
oscillated between 17,430 and 18,939 and never trended downward. At ~15s per
request only about four fit inside the sliding minute, so tokens age out of the
window as fast as they are consumed. A per-minute ceiling is not reachable by a
single sequential caller issuing slow requests.

**Concurrency has to be real to prove anything.** A first attempt used
PowerShell `Start-Job`. Runspace startup costs a few hundred milliseconds each,
so ten "concurrent" requests actually arrived spread over several seconds — slow
enough to slip under a per-second limit. Ten 200s, no throttling, and a
completely misleading pass. Switching to async `HttpClient.SendAsync` dispatched
all ten within **57 ms**:

| Result | Count | Retry-After | Token headers |
| --- | --- | --- | --- |
| 200 OK | 5 | — | present |
| 429 from `rate-limit-by-key` | 5 | 1–2s | **absent** |
| 429 from `llm-token-limit` | 0 | — | — |

**`llm-token-limit` cannot reject a concurrent request.** With
`estimate-prompt-tokens="false"` it has no token count until the response comes
back, so it cannot pre-charge. In a 10-way burst every request cleared the
inbound check against a counter nothing had yet incremented, and each reported
`remaining ≈ 18,400` — its own consumption only, blind to the other nine.
Roughly 16,000 tokens went through a 20,000 ceiling while every caller believed
1,600 had been used.

**The documented "counters are per gateway" overshoot is measurable.**
`calls="2"` with `renewal-period="1"` let **five** simultaneous requests through,
not two. The counter is per gateway node, so the effective concurrency ceiling is
`calls × node count` — and node count is not a value the sample controls or can
pin.

**Consequences, which the docs and threat model must state plainly:**

- The concurrency guard is `rate-limit-by-key`. It is coarse, it overshoots by
  the gateway's node count, and it is the *only* thing standing between one
  identity and a burst.
- `llm-token-limit` is an **after-the-fact** ceiling. It restrains a sustained
  caller over time; it does not bound an instantaneous burst.
- Neither is a billing control. A burst can exceed the TPM ceiling before the
  policy is aware any of it happened. Azure Cost Management remains the
  financial source of truth.
- Setting `estimate-prompt-tokens="true"` would let the policy pre-charge and
  close part of this gap, at the cost of charging estimated rather than actual
  prompt tokens. That trade is not taken here, and the reason is recorded in
  `policies/fragments/token-governance.xml`.

---

## G6 — Correlation, SSE, and the downstream trace boundary

**Documented.** APIM diagnostics support `httpCorrelationProtocol = W3C`.
Backend forwarding defaults to `buffer-response=true`; SSE requires setting it
to `false`, and Microsoft warns that even **request-body diagnostic logging**
can disrupt SSE.
([forward-request](https://learn.microsoft.com/azure/api-management/forward-request-policy),
[SSE guidance](https://learn.microsoft.com/azure/api-management/how-to-server-sent-events),
[diagnostic contract](https://learn.microsoft.com/rest/api/apimanagement/diagnostic/create-or-update?view=rest-apimanagement-2024-05-01))

**Documented.** Foundry returns `apim-request-id` on Responses calls, described
as *"a request ID used for troubleshooting purposes."*
([Responses REST reference](https://learn.microsoft.com/rest/api/microsoft-foundry/azureopenai/responses))

**Unresolved.** No first-party source was found guaranteeing that
`x-ms-client-request-id` is echoed, persisted, or queryable for Responses, nor
that Foundry exposes internal W3C spans to the caller.

**Design consequence.** The correlation chain that this repository may claim is
`client → APIM request → APIM backend dependency → captured Foundry request ID`.
Anything beyond that is a support handle, not a joinable trace. Send
`x-ms-client-request-id` opportunistically; do not document it as observable.

| Check | Status |
| --- | --- |
| W3C diagnostics and non-buffered forwarding | Documented |
| `apim-request-id` present on Responses | Documented |
| `x-ms-client-request-id` observable downstream | **Unresolved — do not claim** |
| Real end-to-end join on success and error | **Pending** |

---

## G7 — Request validation ceilings

**Unresolved (documented contradiction).** The `validate-content` policy
reference permits `max-size` up to **4 MB**, while the gateway runtime limits
table lists **100 KiB** for bodies processed by `validate-content`, alongside a
separate **2 MiB** buffered-payload limit for v2. These are different limits and
must not be conflated.
([validate-content](https://learn.microsoft.com/azure/api-management/validate-content-policy),
[gateway runtime limits](https://learn.microsoft.com/azure/api-management/api-management-gateways-overview#gateway-runtime-limits))

**Documented.** `set-header` cannot alter or delete `Connection`,
`Content-Length`, `Keep-Alive`, or `Transfer-Encoding`, cannot remove the
client-IP component of `X-Forwarded-For`, and cannot delete the response
`Server` header.
([set-header limitations](https://learn.microsoft.com/azure/api-management/set-header-policy#limitations))

**Design consequence.** The initial request cap is **64 KiB** — below the lowest
documented ceiling. The repository documents transport headers it *cannot*
remove rather than claiming a perfect allowlist.

| Check | Status |
| --- | --- |
| 512 KiB passes the deployed gateway | **Empirical** - the 100 KiB runtime-table figure does not govern this path |
| Immutable transport headers | Documented |
| Behavior with missing `Content-Length`, chunked, and compressed bodies | **Empirical — see below** |

### Empirical: 14 hostile requests, all fail closed

Reproduce with `scripts/verify-request-validation.ps1`. Uses `HttpClient`
rather than `Invoke-WebRequest` because these cases need exact byte counts,
chunked framing with no `Content-Length`, raw invalid UTF-8, gzip content
coding, and JSON that `ConvertTo-Json` will not produce.

A **500 is a failure here even when the request is garbage**, and so is a 200.
Every rejection is additionally checked for an `x-correlation-id` and scanned
for leaked internals (backend hostnames, `Microsoft.ApiManagement`, stack
traces, bearer tokens).

The suite also carries a **positive control** — one valid request that must
return 200. Without it the whole suite would pass against a gateway that
rejects everything, which is not the property under test.

| Case | Result |
| --- | --- |
| valid baseline request (control) | 200 |
| body just under the cap | 400 |
| body over the cap | 400 |
| chunked, no `Content-Length` | 400 |
| gzip `Content-Encoding` | 400 |
| malformed UTF-8 | 400 |
| duplicate `store` key (`false` then `true`) | 400 |
| explicit `store:true` | 400 |
| `store` as the string `"false"` | 400 |
| deeply nested JSON (200 levels) | 400 |
| unknown top-level property (`previous_response_id`) | 400 |
| `tools` array | 400 |
| truncated JSON | 400 |
| `text/plain` content type | 415 |

**Two real defects, both found only by sending these.** The offline suite was
green throughout.

1. **Malformed UTF-8 returned 200 and reached the model.** APIM's JSON reader
   substitutes U+FFFD for invalid byte sequences rather than rejecting them, so
   a body containing `C3 28 A0 A1` was silently repaired and forwarded. "Fail
   closed on unsupported encodings" was simply untrue. Fixed with a byte-exact
   UTF-8 round-trip check — see D7 for why the obvious `UTF8Encoding` approach
   cannot be used.

2. **Truncated JSON returned 500 `backend_error`.** `Body.As<JObject>()` threw,
   the exception fell through to `on-error`, and a **client** mistake was
   reported as a **backend** fault. That is worse than an unhelpful status: it
   points whoever is on call at the wrong system entirely.

Both now reject with 400 and a sanitized `invalid_request`.

---

## G8 — Private networking and the bypass problem

**Documented.** Standard v2 supports an inbound private endpoint **and**
outbound VNet integration simultaneously. Public network access is disabled
**after** the instance and private endpoint exist. The integration subnet must
be dedicated, delegated to `Microsoft.Web/serverFarms`, and carry an NSG;
minimum `/27`, `/24` recommended. Inbound NSG rules on the *integration* subnet
do not restrict APIM ingress.
([virtual network concepts](https://learn.microsoft.com/azure/api-management/virtual-network-concepts),
[private endpoint](https://learn.microsoft.com/azure/api-management/private-endpoint),
[outbound integration](https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound))

**Documented — this is the crux of the whole design.** Private endpoints are
reachable from peered VNets, VPN, and ExpressRoute, and the default
`AllowVNetInBound` rule permits that traffic. A private endpoint **alone does
not stop an authorized developer** from calling Foundry directly.
([private endpoint overview](https://learn.microsoft.com/azure/private-link/private-endpoint-overview),
[NSG default rules](https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview#default-security-rules))

**Design consequence.** The Foundry private-endpoint subnet must enable
private-endpoint network policies and carry explicit rules that allow TCP 443
**only** from the APIM integration subnet, then deny other sources — including
the jumpbox subnet, whose user holds valid inference RBAC. DNS is not a security
boundary; a developer can supply the hostname and address manually.

| Check | Status |
| --- | --- |
| Simultaneous private inbound + outbound integration | **Empirical** — `publicNetworkAccess: Disabled` with `virtualNetworkType: External`, both PEs Approved |
| Public disablement must follow PE creation | **Empirical** — ordered bootstrap applied cleanly |
| PE alone is insufficient against authorized humans | Documented; mitigated by NSG rules below |
| Authorized human blocked from the public internet | **Empirical — see below** |
| Repeated `terraform apply` never reopens public access | **Empirical** — second apply reported `No changes`, `0 added, 0 changed, 0 destroyed`, both endpoints still `Disabled` |
| APIM succeeds and direct Foundry fails **from the jumpbox** | **Blocked by G4** — the inside-the-VNet half is unproven |

### Empirical: deployed once to a second resource group, verified, destroyed

Deployed to `rg-map-map-private-*` in an isolated Terraform workspace, so the
public environment could not be touched.

**A fresh apply found a bug the public deployment had hidden.**
`azurerm_role_assignment.inference_broker` used
`count = var.identity_mode == "brokered" && var.broker_principal_id != null`.
That is fine when APIM already exists, and fails on a clean deployment with
`Invalid count argument`, because the gateway's principal ID is unknown until
it is created. The public environment never hit it — brokered mode was applied
in place to an existing gateway. The null check moved to a `precondition`,
which Terraform defers to apply time. **A pattern converted in place is not a
pattern that has been deployed.**

**Measured posture:**

| Control | Observed |
| --- | --- |
| APIM `publicNetworkAccess` | `Disabled` |
| Foundry `publicNetworkAccess` | `Disabled` |
| Foundry `networkAcls` | `defaultAction: Deny`, `bypass: None`, no IP or VNet rules |
| Foundry `disableLocalAuth` | `true` |
| Private endpoints | `pe-apim`, `pe-openai`, both `Approved` |

**Anti-bypass NSG rules on the Foundry PE subnet**, in priority order:

| Priority | Rule | Effect |
| --- | --- | --- |
| 100 | `Allow-APIM-Integration-Only` | 10.43.0.0/24 → PE :443 |
| 200 | `Deny-Jumpbox-Direct-To-Model` | 10.43.3.0/24 → PE, all ports |
| 4000 | `Deny-All-Other-VNet-Traffic` | everything else |

The jumpbox is allowed to reach the gateway PE on 443 and explicitly denied the
model PE — both ahead of the default `AllowVNetInBound`.

**The authorized-human test, and why the first attempt proved nothing.**
Calling Foundry directly from the public internet returned 401, which looks
like a pass and is not one: in brokered mode no human holds inference RBAC, so
that 401 cannot distinguish a network block from an RBAC block. The claim under
test is specifically that the *network* stops an *authorized* caller.

Granting the test identity `Cognitive Services OpenAI User` at account scope and
retrying settles it. The error text changed, which is the tell:

| Stage | Response |
| --- | --- |
| Before RBAC | 401 — *"lacks the required data action `...OpenAI/responses/write`"* |
| After RBAC propagated | 401 — *"Principal does not have access to API/Operation."* |

The specific dataAction complaint disappears, confirming RBAC took effect, and
access is **still denied**. The network boundary holds against an authorized
principal. The grant was removed immediately afterwards.

**Operational warning — Foundry hides the reason, APIM states it.** Compare the
two denials for the same network condition:

- APIM: `403 ... Request originated from client public IP address 172.200.70.13,
  public network access on this Microsoft.ApiManagement/service/... is disabled.`
- Foundry: `401 PermissionDenied ... does not have access to API/Operation.`

Foundry reports a **network** denial with an **authorization-shaped 401** and
never mentions the network. Anyone debugging this will reasonably conclude they
have an RBAC problem and go grant permissions that are already correct. When a
private-pattern call fails, check `publicNetworkAccess` and the effective NSG
rules *before* touching role assignments.

**Still unproven, and not claimed:** that a developer inside the VNet succeeds
through the gateway. That requires the jumpbox, which G4 blocks. The private
pattern is therefore verified as *closed* but not yet verified as *usable*.

---

## G9 — Terraform state contents

**Source-observed** against `hashicorp/terraform-provider-azurerm` v5.5.0:

| Resource | Behavior |
| --- | --- |
| `azurerm_cognitive_account` with local auth disabled at creation | Skips `AccountsListKeys`; supports avoiding initial key storage |
| `azurerm_log_analytics_workspace` | Reads and stores shared keys regardless of the local-auth flag |
| `azurerm_application_insights` | Stores instrumentation key and connection string |
| `azurerm_api_management_subscription` | Calls `ListSecrets` and stores both keys |
| `azurerm_windows_virtual_machine` | Stores the administrator password (documented) |

**Documented.** An Application Insights instrumentation key is an *identifier,
not a security token*. Terraform `sensitive` redacts display only; it does not
remove values from state.
([connection strings](https://learn.microsoft.com/azure/azure-monitor/app/sdk-connection-string),
[managing sensitive data](https://developer.hashicorp.com/terraform/language/manage-sensitive-data))

**Design consequence — the agreed contract.** *No reusable authentication
secret* in state, plans, outputs, or logs. Telemetry identifiers are permitted
and explicitly classified. Log Analytics is therefore created through AzAPI to
avoid the shared-key read, and no `azurerm_api_management_subscription`
resource is declared. Every APIM instance still ships with a built-in
all-access subscription, which is disabled without reading its keys.
([APIM subscriptions](https://learn.microsoft.com/azure/api-management/api-management-subscriptions))

| Check | Status |
| --- | --- |
| Provider key-read behavior per resource | Source-observed at v5.5.0 |
| Instrumentation key classified as identifier | Documented |
| Field-level state inspection showing no credential material | **Empirical — see below** |

### Empirical: audited the live public state, field by field

Reproduce with `scripts/audit-state-secrets.ps1`. It walks every attribute of
every resource, flags any leaf whose *name* suggests a credential, and then
**classifies** rather than merely counting. Values are never printed; findings
carry a length and a truncated SHA-256 so runs can be compared safely.

Audited against the live public deployment: **23 resources, zero violations.**

Every match was a permitted non-credential:

| Attribute | Classification |
| --- | --- |
| `azurerm_application_insights.main.connection_string` | Telemetry ingestion identifier. Grants nothing on the model, gateway, or any host. |
| `azurerm_application_insights.main.instrumentation_key` | Same — a telemetry write identifier. |
| `azurerm_api_management_logger.app_insights...connection_string` | Same value, consumed by the logger. |
| `azurerm_api_management.main...proxy.0.certificate_source` | The enum `"BuiltIn"`. Not a certificate — and the sibling `certificate` and `certificate_password` fields are both empty, which is what actually matters. |

**The avoidance choices are confirmed to have worked, by absence:**

| Expected risk | Outcome in state |
| --- | --- |
| `azurerm_log_analytics_workspace` stores shared keys | **Resource is not present.** The workspace is `azapi_resource.workspace`, whose `response_export_values` exports only `properties.customerId` — a workspace identifier. No shared key is read or stored. |
| `azurerm_api_management_subscription` calls `ListSecrets` | **Resource is not declared.** The built-in all-access subscription is disabled through `azapi_resource_action`, which issues a PATCH and never reads keys. |
| `azurerm_windows_virtual_machine` stores the admin password | Not present in the public profile. Remains the open question in G4. |

The auditor also checks that no `*.tfplan`, `tfplan.binary`, or
`*.tfstate.backup` is tracked in git — a saved plan is state under another
name, and `.gitignore` has twice been found with a gap here.

**Honest limit.** This proves state is clean *for the public profile*. The
private profile adds no key-reading resource, but with `enable_test_access =
true` it would add the Windows VM, and G4 is precisely the unresolved question
of whether that can be done without a password in state.

---

## G10 — Telemetry that cannot leak payloads

**Documented.** Foundry resource-log categories are `Audit`,
`AzureOpenAIRequestUsage`, `ManagedNetworkEvent`, `RequestResponse`, and
`Trace`.
([supported logs](https://learn.microsoft.com/azure/azure-monitor/reference/supported-logs/microsoft-cognitiveservices-accounts-logs))

**Unresolved.** A category name does not establish that its contents are
payload-free.

**Design consequence.** `allLogs` is never enabled. `RequestResponse` and
`Trace` are explicitly excluded. Additional categories are enabled only after
schema review and controlled inspection. APIM diagnostics set zero body bytes on
**all four** legs (frontend/backend × request/response), and automatic exception
telemetry is inspected because body logging being off is not by itself proof of
sanitization.

| Check | Status |
| --- | --- |
| Category list and the exclusions we apply | Documented |
| Category contents are payload-free | **Unresolved — excluded by default** |
| Canary strings absent from all telemetry at max verbosity | **Pending** |

---

## G11 — Deployment target, model, and tooling lifecycle

**Documented.** Model GA status, API GA status, regional availability,
new-deployment eligibility, quota, and processing residency are **separate**
checks. Capacity-unit-to-TPM conversion varies by model.
([region availability](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure-region-availability),
[model retirements](https://learn.microsoft.com/azure/foundry/openai/concepts/model-retirements),
[quota](https://learn.microsoft.com/azure/foundry/openai/how-to/quota))

**Documented.** azd's Terraform integration is labeled **beta**. This was
accepted as a *tooling* risk; Azure runtime features remain GA.
([azd + Terraform](https://learn.microsoft.com/azure/developer/azure-developer-cli/use-terraform-for-azd))

**Pending input.** No subscription, tenant, region, model, version, SKU, or
capacity has been selected. `infra/variables.tf` therefore has **no default
model or region** — deployment fails closed until an operator chooses and
records a verified tuple.

| Check | Status |
| --- | --- |
| Separate lifecycle checks required | Documented |
| azd Terraform beta accepted | Documented + approved |
| Chosen region/model/version/SKU/capacity tuple | **Pending input — no default supplied** |

---

## Summary of what blocks what

| Gate | Blocks | Can scaffolding proceed? |
| --- | --- | --- |
| G1 audience | Pinning APIM `aud` | Yes — variable, no default |
| G2 claim set | Client allowlist values | Yes — variable, no default |
| G3 VS Code flow | Extension acceptance | Yes — code written, untested against Entra |
| **G4 Windows access** | **`map-p07` completion** | Yes — module exists, gated by a variable that fails closed |
| G5 llm policies | 429 normalization only | Enforcement **proven**; concurrency limits measured and documented |
| G6 correlation | Observability acceptance | Yes |
| G7 ceilings | Final size cap | **Proven** — 14 hostile cases fail closed; two defects found and fixed |
| G8 bypass | Private-pattern acceptance | Deployed, verified, destroyed; inside-VNet half blocked by G4 |
| G9 state | State acceptance | **Audited** — 23 resources, zero violations |
| G10 telemetry | Privacy acceptance | Yes — excluded by default |
| G11 target | **Any deployment at all** | Yes — fails closed without input |
