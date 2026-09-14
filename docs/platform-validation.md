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
> [`implementation-plan.md`](implementation-plan.md) may be marked satisfied.

Documentation was reviewed on **2026-09-14**. Re-verify volatile rows against the
versions pinned in [`versions.md`](versions.md) before deployment.

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
| Endpoint path and no `api-version` requirement | Documented |
| Scope string used by first-party SDK samples | Documented |
| Actual `aud` claim issued for that scope | **Pending — blocks pinning the APIM audience** |
| Same `aud` from VS Code and Azure CLI | **Pending** |

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
| Fixed-tenant validation with validated-token output | Documented |
| `scp` present only on delegated tokens | Documented |
| Observed claim set for the VS Code client and Azure CLI client | **Pending — determines the client allowlist** |

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

| Check | Status |
| --- | --- |
| `getSession` availability and options | Documented |
| Tenant pinning via `VSCODE_TENANT:` | Source-observed |
| Host compatibility constraints for forks | Source-observed |
| Real interactive sign-in, consent, refresh, sign-out, cancel | **Pending** |

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
another option is approved. See [`docs/private-test-access.md`](private-test-access.md).

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
| Policy accepted on Standard v2 with our attribute set | **Pending** |
| Daily-quota 403 reliably distinguishable from RBAC 403 | **Pending — gates the approved 429 normalization** |
| Per-user counter isolation across refreshed tokens | **Pending** |

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
| Conservative 64 KiB cap is within every documented ceiling | Documented |
| Immutable transport headers | Documented |
| Behavior with missing `Content-Length`, chunked, and compressed bodies | **Pending** |

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
| Simultaneous private inbound + outbound integration | Documented |
| Public disablement must follow PE creation | Documented |
| PE alone is insufficient against authorized humans | Documented |
| APIM succeeds and direct Foundry fails from the jumpbox | **Pending — the central private-pattern proof** |
| Repeated `terraform apply` never reopens public access | **Pending** |

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
| Field-level state inspection showing no credential material | **Pending** |

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
| G5 llm policies | Quota acceptance, 429 normalization | Yes — policy written, untested |
| G6 correlation | Observability acceptance | Yes |
| G7 ceilings | Final size cap | Yes — conservative cap chosen |
| G8 bypass | Private-pattern acceptance | Yes — rules written, unproven |
| G9 state | State acceptance | Yes — AzAPI avoidance implemented |
| G10 telemetry | Privacy acceptance | Yes — excluded by default |
| G11 target | **Any deployment at all** | Yes — fails closed without input |
