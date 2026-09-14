# Cyber review pack

A reviewer should be able to assess this solution **without reverse-engineering
Terraform or APIM XML**. That is what this document is for.

**Current status: scaffolded and validated offline. Never deployed.** Every
"Evidence" entry below marked *pending* requires a live deployment.

---

## 1. Data flow

```text
Developer (Entra human identity)
   │  Entra access token · x-correlation-id · traceparent
   ▼
Azure API Management  (policy enforcement boundary)
   │  validate token · authorize human · scrub headers · validate schema
   │  enforce model allowlist · enforce store=false · per-user quotas
   │  SAME bearer token, unchanged
   ▼
Azure OpenAI v1 Responses  (model execution boundary)
   │  Entra RBAC authorizes the same human
   ▼
Coding model
```

Telemetry runs sideways to this path and carries **metadata only**.

## 2. Trust boundaries

| # | Boundary | Crossing control |
| --- | --- | --- |
| 1 | Workstation → gateway | TLS + Entra token; client refuses non-HTTPS |
| 2 | Gateway ingress | Token validation, delegated-human check, client allowlist |
| 3 | Gateway → Foundry | Original token forwarded; private network in the private pattern |
| 4 | Foundry authorization | Independent Entra RBAC on the same principal |
| 5 | Runtime → telemetry | Metadata only; zero body bytes |

## 3. Authentication

| Question | Answer |
| --- | --- |
| Who authenticates? | The developer, via Microsoft Entra |
| How many tenants? | Exactly one, a literal GUID |
| What is validated? | Signature, expiry, issuer, tenant, audience |
| Any shared credential? | **No.** No API key, client secret, or subscription key |
| Is identity preserved? | **Yes** — the token is forwarded byte-for-byte |
| Enforced how? | Build-time invariant tests fail if a credential-substituting policy appears |

## 4. Authorization

| Layer | Check |
| --- | --- |
| Gateway | Delegated human (`scp` present, `idtyp != app`), approved client app |
| Gateway | Model allowlist, schema allowlist, per-user quotas |
| Foundry | Azure RBAC: `Cognitive Services OpenAI User` on the account |

Separation of duties:

| Duty | Principal |
| --- | --- |
| Provision infrastructure | azd/Terraform principal |
| Administer APIM | Azure RBAC, separate |
| **Call the model** | **Named humans/groups only** |
| Publish telemetry | APIM managed identity (no inference rights) |
| Sign in to jumpbox | VM User Login (no inference rights) |

## 5. Token lifecycle

Acquired by VS Code's built-in provider or Azure CLI · cached and refreshed by
them · forwarded unchanged · **never** persisted, logged, or exported by this
repository.

## 6. Network

| | Public | Private |
| --- | --- | --- |
| APIM ingress | Public HTTPS | Private endpoint; public disabled |
| Foundry ingress | Public + RBAC | Private endpoint; public disabled |
| Gateway → model | Public | Outbound VNet integration |
| **Direct bypass** | **Possible (accepted)** | **NSG-denied** |

> The private pattern's key insight: **a private endpoint alone is not a
> control**, because it is reachable over peering, VPN, and ExpressRoute under
> the default `AllowVNetInBound` rule. Explicit deny rules are the control.

## 7. Encryption in transit

TLS enforced end to end. HSTS and `nosniff` set on responses.

> **Limitation.** APIM v2 tiers do not expose the classic cipher-configuration
> surface. No `security` block is declared, because declaring unsupported
> knobs produces error or drift.

## 8. Data persistence

| Data | Persisted? |
| --- | --- |
| Prompts / source code | **No** — `store:false` enforced |
| Model output | **No** |
| Conversation state | **No** — client-side only |
| Telemetry metadata | Yes — Log Analytics, configurable retention |
| Jumpbox working files | Yes — on the VM disk (private pattern) |

> **Limitation.** `store:false` governs Responses storage. It is **not** a
> claim about Azure OpenAI abuse monitoring, which is a separate feature.

## 9. Logging and data classification

| Class | Examples | Logged? |
| --- | --- | --- |
| Secret | Tokens, keys | **Never** |
| Sensitive content | Prompts, source, output | **Never** |
| Direct identifiers | UPN, email, display name | **Never** |
| Pseudonymous | `tid`, `oid` | Yes — access-controlled logs only |
| Operational | Correlation/trace/request IDs, status, timing | Yes |

## 10. Secrets management

There are none at runtime. Local key auth disabled at creation; no subscription
required; built-in all-access subscription suspended.

**State contract:** no reusable authentication secret in state, plans, outputs,
or logs.

> **For the reviewer to decide:** the App Insights connection string *is* in
> state, classified as a telemetry identifier (Microsoft documents the
> instrumentation key as an identifier, not a security token; local auth is
> disabled so the string alone cannot ingest). If your standard requires zero
> key-*named* fields in state, this is the item to examine.

## 11. Rate limiting

Per-user TPM, daily quota, concurrency, size, and output caps — keyed on
validated `tid:oid`.

> **Not billing controls.** Counters are per-gateway and can overshoot;
> streaming prompt tokens are always estimated; `Daily` is a fixed UTC day.
> **Use Azure Cost Management and budget alerts.**

## 12. Control matrix

| Control | Implementation | Evidence | Residual risk |
| --- | --- | --- | --- |
| Single-tenant auth | `validate-azure-ad-token`, literal GUID | `policies/fragments/authentication.xml` | Stolen token within validity |
| Delegated human only | `scp` + `idtyp` checks | Same; `tests/contract/test_policy_invariants.py` | Not proof of presence |
| Token preservation | No credential policy anywhere | Invariant tests + `validate-policies.ps1` | None identified |
| Header scrubbing | Delete before read | `security-headers.xml` | Transport headers immutable |
| Schema allowlist | `additionalProperties:false` | `specs/responses-request.schema.json` | None identified |
| Model allowlist | Policy value check | `request-validation.xml` | None identified |
| Stateless | Reject `true`, inject `false` | `request-validation.xml` | Abuse monitoring separate |
| Per-user quotas | `llm-token-limit` on `tid:oid` | `token-governance.xml` | Approximate; can overshoot |
| No payload logging | Zero body bytes ×4 legs | `infra/modules/gateway/main.tf` | **Pending** canary test |
| No inference MI | No Cognitive role on any MI | `infra/modules/gateway/main.tf` | None identified |
| Least privilege | `Cognitive Services OpenAI User` | `infra/modules/foundry/main.tf` | Broader than Responses |
| No runtime keys | Local auth disabled at creation | `infra/modules/foundry/main.tf` | None identified |
| State safety | AzAPI for key-reading resources | `monitoring/main.tf`, `gateway/main.tf` | Telemetry identifiers present |
| **Anti-bypass** | **NSG deny on Foundry PE** | `infra/modules/networking/main.tf` | **Pending** live proof |
| SSE preserved | `buffer-response="false"` | `policies/responses.xml` | **Pending** timing test |
| Correlation | W3C + GUID + backend ID capture | `correlation.xml`, `responses.xml` | Chain ends at gateway |
| No auto-retry | No retry policy; clients set 0 | `responses.xml`, clients | None identified |

## 13. Dependencies

| Component | Dependencies | Pinned by |
| --- | --- | --- |
| Infrastructure | azurerm 5.5.0, azapi 2.12.0, random 3.9.1 | `.terraform.lock.hcl` |
| Python client | openai, azure-identity | `uv.lock` |
| VS Code extension | **none at runtime** | `package-lock.json` |
| Gateway policy | none | — |

## 14. Deployment controls

Terraform is the only IaC. No portal configuration on the happy path. Preflight
fails closed on toolchain and policy invariants. CI runs offline with **no
Azure credentials**, so fork PRs are safe.

No default region or model is supplied — deployment fails closed until an
operator verifies availability, eligibility, quota, and residency.

## 15. Incident troubleshooting

1. User reports a **correlation ID**.
2. Run [`queries/correlation.kql`](../queries/correlation.kql) → gateway
   request, backend dependency, `tid`/`oid`, status, timing.
3. Resolve `oid` to a person via a separate Entra lookup (intended friction).
4. For backend issues, quote the **Foundry request ID** to Microsoft support.

> The chain ends at the gateway. The Foundry request ID is a support handle,
> not a joinable trace.

## 16. Known limitations

| # | Limitation |
| --- | --- |
| 1 | **Nothing has been deployed.** No control is empirically verified. |
| 2 | **Gate G4 unresolved** — Windows jumpbox cannot be GA + passwordless + secret-free simultaneously. Fails closed. |
| 3 | Public pattern permits the direct bypass by design. |
| 4 | Quotas are approximate safeguards, not billing controls. |
| 5 | Correlation ends at the gateway boundary. |
| 6 | `store:false` ≠ no abuse-monitoring retention. |
| 7 | `Cognitive Services OpenAI User` is broader than Responses. |
| 8 | Some transport headers cannot be removed. |
| 9 | APIM v2 does not expose cipher configuration. |
| 10 | azd Terraform integration is documented as beta. |
| 11 | A private endpoint alone would not prevent bypass — NSG rules do. |
| 12 | App Insights connection string is in state as a telemetry identifier. |

## 17. Reviewer checklist

- [ ] Confirm no credential-substituting policy — run `scripts/validate-policies.ps1`
- [ ] Confirm zero body bytes on all four diagnostic legs
- [ ] Confirm no managed identity holds a Cognitive Services role
- [ ] Confirm local key auth is disabled on the Foundry account
- [ ] **Confirm the direct bypass fails on the private pattern, from the jumpbox, with valid RBAC**
- [ ] Run the canary test and confirm no prompt/output in telemetry
- [ ] Inspect Terraform state field-by-field
- [ ] Confirm repeated `terraform apply` does not reopen public access
- [ ] Decide whether the App Insights connection-string classification is acceptable
- [ ] Decide on gate G4 before enabling the jumpbox

Detail: [`security.md`](security.md) · [`threat-model.md`](threat-model.md) ·
[`platform-validation.md`](platform-validation.md)
