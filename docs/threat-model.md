# Threat model

Scope: the runtime path from a developer's IDE to the model, plus the
deployment and telemetry that support it.

Format per threat: **control → implementation → residual risk → verification**.

Residual risk is stated honestly. A threat model with no residual risk is a
marketing document.

---

## T1 — Stolen Entra token

**Attacker replays a valid access token captured from a developer's machine.**

| | |
| --- | --- |
| **Control** | Short token lifetime; Entra Conditional Access; no extension-managed token store |
| **Implementation** | VS Code owns caching/refresh; the extension calls `getSession` per invocation and persists nothing. Python uses `AzureCliCredential`. No refresh token is ever written by this repository. |
| **Residual risk** | **HIGH within the token's validity window.** A valid token is a valid token — the gateway cannot distinguish a thief from the user. Per-user quotas bound the damage; they do not prevent it. |
| **Verification** | Confirm no token appears in settings, workspace state, logs, or telemetry. Confirm `oid` in telemetry attributes the call to the victim, giving investigators a starting point. |

Mitigation belongs at the identity layer: Conditional Access, device
compliance, token protection, short lifetimes.

---

## T2 — Wrong-tenant token

**Attacker presents a valid token from a different tenant.**

| | |
| --- | --- |
| **Control** | `validate-azure-ad-token` with a literal tenant GUID |
| **Implementation** | `map-tenant-id` named value; Terraform rejects `common`/`organizations` |
| **Residual risk** | **LOW.** Returns **401**, not 403. Emitting 403 only for tenant mismatch would require reading an *unvalidated* `tid` to choose a status — attacker-controlled data before authentication. |
| **Verification** | Token from another tenant → 401. |

---

## T3 — Application-only token

**A service principal calls the endpoint, defeating human attribution.**

| | |
| --- | --- |
| **Control** | Delegated-identity check |
| **Implementation** | Reject `idtyp == "app"`; require `scp`, `tid`, `oid`; enforce client-app allowlist |
| **Residual risk** | **MEDIUM.** Establishes a *delegated* identity, not a person at the keyboard. A service principal that can obtain delegated tokens through a compromised user still passes. |
| **Verification** | Client-credentials token → 403 `not_delegated_identity`. |

> Note: the check does **not** reject on the presence of a `roles` claim, since
> humans can hold app roles.

---

## T4 — Header spoofing

**Caller forges `x-user-id` or `x-foundry-request-id` to corrupt attribution.**

| | |
| --- | --- |
| **Control** | Scrub identity and gateway-metadata headers before anything reads them |
| **Implementation** | `security-headers.xml` runs *before* authentication; gateway metadata is generated after validation from claims only |
| **Residual risk** | **LOW.** `Connection`, `Content-Length`, `Keep-Alive`, `Transfer-Encoding`, and the client-IP part of `X-Forwarded-For` cannot be removed — platform limitation, no identity impact. |
| **Verification** | Send spoofed headers; confirm attribution is to the real caller and the returned `x-foundry-request-id` is the real backend value. |

---

## T5 — Correlation-ID injection

**Caller supplies a malicious correlation value to poison telemetry.**

| | |
| --- | --- |
| **Control** | GUID validation with length bound; replace on failure |
| **Implementation** | Anchored regex, 36-char check; malformed values replaced, never echoed. Value is telemetry-only. |
| **Residual risk** | **LOW.** A caller can reuse *another* valid GUID, muddying a search. They gain no authorization, since the ID is never used for authentication, authorization, or routing. |
| **Verification** | Inject `not-a-guid'; DROP TABLE--`; confirm a fresh GUID is returned and the payload is absent from telemetry. |

---

## T6 — Model enumeration

**Caller probes for other deployments.**

| | |
| --- | --- |
| **Control** | Exactly one deployment; policy-level value check |
| **Implementation** | Single `azurerm_cognitive_deployment`; `map-approved-deployment` comparison; only `POST /responses` exposed — no model-list operation |
| **Residual risk** | **LOW.** |
| **Verification** | Request another deployment name → 400 `unapproved_model`. |

---

## T7 — Quota abuse / denial of wallet

**A user drives cost through volume.**

| | |
| --- | --- |
| **Control** | Per-user TPM, daily quota, concurrency cap, output-token bound, request size cap |
| **Implementation** | `llm-token-limit` + `rate-limit-by-key` keyed on `tid:oid` |
| **Residual risk** | **MEDIUM.** Counters are per-gateway and concurrent requests can **overshoot**. Streaming prompt tokens are always estimated. `Daily` resets at UTC midnight. These bound spend approximately, not exactly. |
| **Verification** | Exceed TPM → 429 + `Retry-After`. Confirm two users have isolated counters and that token refresh does not reset a counter. **Set an Azure budget alert — the gateway is not a billing control.** |

---

## T8 — Prompt or source-code leakage via telemetry

**Proprietary code reaches logs.**

| | |
| --- | --- |
| **Control** | Zero body bytes on all four diagnostic legs; header allowlist; fixed trace messages; Foundry categories restricted |
| **Implementation** | `azurerm_api_management_diagnostic` with `body_bytes = 0` throughout; `allLogs` never enabled; `RequestResponse`/`Trace` excluded |
| **Residual risk** | **MEDIUM until verified.** A category name does not prove its contents are payload-free. Automatic exception telemetry is a separate path from request logging. |
| **Verification** | Canary test at maximum verbosity, including a **rejected** request. Confirm telemetry actually arrived first — an empty result from broken ingestion is not a pass. |

---

## T9 — Server-side response persistence

**Proprietary code is retained by the service.**

| | |
| --- | --- |
| **Control** | `store:true` rejected; `store:false` injected when omitted |
| **Implementation** | Schema `const: false` plus a defensive policy check |
| **Residual risk** | **MEDIUM.** `store:false` governs *Responses storage* only. It is **not** a claim that Azure OpenAI abuse monitoring retains nothing — that is a separate feature with its own process. |
| **Verification** | `store:true` → 400. Omitted → confirm `false` forwarded. |

---

## T10 — Unapproved Responses features

**Caller reaches tools, MCP, file inputs, or background execution.**

| | |
| --- | --- |
| **Control** | Allowlist schema with `additionalProperties: false` everywhere |
| **Implementation** | `validate-content` against the committed schema |
| **Residual risk** | **LOW.** Fails closed on features that did not exist at review time. A URL inside plain text is inert and accepted — nothing fetches it. |
| **Verification** | `tests/contract/test_request_schema.py` covers each rejected feature. |

---

## T11 — Direct backend bypass ⚠️

**A developer with inference RBAC calls Foundry directly, skipping all
governance: no quotas, no model allowlist, no `store:false`, no telemetry.**

This is the most consequential threat in the model, and the two patterns treat
it differently.

### Public pattern

| | |
| --- | --- |
| **Control** | **None.** |
| **Residual risk** | **ACCEPTED AND HIGH.** Anyone holding `Cognitive Services OpenAI User` can bypass the gateway entirely. |
| **Verification** | The bypass *will* succeed. That is the documented behavior. |

### Private pattern

| | |
| --- | --- |
| **Control** | Explicit NSG deny on the Foundry PE subnet; public access disabled |
| **Implementation** | `private_endpoint_network_policies` enabled (without it the NSG is not evaluated); allow only `snet-apim-integration`; deny `snet-jump` and corporate prefixes; deny-all at 4000 to override `AllowVNetInBound`. Jumpbox NSG mirrors the denial on egress. |
| **Residual risk** | **LOW, but unverified.** A private endpoint alone would **not** suffice — it is reachable over peering, VPN, and ExpressRoute. DNS is not a boundary either. Someone with subscription-level network write could alter the NSG. |
| **Verification** | **The central test.** From the jumpbox, with valid inference RBAC, a direct call must fail. Also test from the corporate network and with a manual hostname/IP override. |

---

## T12 — Excessive RBAC

**Inference identities hold more than they need.**

| | |
| --- | --- |
| **Control** | Least-privileged built-in role at account scope |
| **Implementation** | `Cognitive Services OpenAI User` at account scope only. Never Owner, Contributor, or Cognitive Services Contributor. Who holds it depends on `identity_mode`: in `passthrough`, named human principals and **no** managed identity; in `brokered` (the default), the APIM managed identity and **no** human. A Terraform precondition enforces that exclusivity. The VM identity holds no Cognitive Services role in either mode. |
| **Residual risk** | **MEDIUM.** The role is broader than Responses — it also covers completions, embeddings, images, assistants, and video. A narrower custom role is a documented hardening option, not a default. In `brokered` mode the gateway calls the model for whoever its policy admits, so **RBAC is no longer the control that decides who reaches the model** — the gateway's own authorization is (see T19). |
| **Verification** | Enumerate assignments on the account; confirm no managed identity appears. |

---

## T13 — Terraform state exposure

**State reveals credentials.**

| | |
| --- | --- |
| **Control** | No reusable authentication secret in state |
| **Implementation** | Log Analytics via AzAPI; no APIM subscription resource; Foundry local auth disabled at creation; App Insights connection string is a module-internal output |
| **Residual risk** | **LOW–MEDIUM.** App Insights connection string *is* in state, classified as a telemetry identifier. Local state is plaintext. Historical state is never retroactively sanitized. |
| **Verification** | Inspect state field-by-field. Confirm `.gitignore` excludes state, plans, and `.azure`. |

---

## T14 — Jumpbox compromise

**The private test VM is misused.**

| | |
| --- | --- |
| **Control** | No public IP; Bastion-only RDP; Entra sign-in; least-privilege VM role; **denied direct model access** |
| **Implementation** | NSG allows RDP only from the Bastion subnet; `Virtual Machine User Login` (not Administrator); jumpbox subnet explicitly denied at the Foundry PE |
| **Residual risk** | **MEDIUM, and gate G4 is unresolved.** A bootstrap local account exists until Entra sign-in is confirmed healthy. Source opened in VS Code persists on the VM disk. Bastion's endpoint is public. |
| **Verification** | Confirm no public IP; confirm the bootstrap account is disabled; confirm direct model access fails from the VM. |

---

## T15 — Supply chain

**A compromised dependency exfiltrates tokens or code.**

| | |
| --- | --- |
| **Control** | Pinned versions, committed lockfiles, minimal dependencies, CI secret scanning |
| **Implementation** | `.terraform.lock.hcl`, `uv.lock`, `package-lock.json` all committed; extension has **zero** runtime dependencies; gitleaks in CI |
| **Residual risk** | **MEDIUM.** The Python client depends on the OpenAI SDK and azure-identity, which have transitive dependencies. Jumpbox bootstrap installs from vendor sources via winget. |
| **Verification** | `npm ci` / `uv sync --locked` reproduce exactly; enable Dependabot. |

---

## T16 — Malicious endpoint configuration

**An attacker redirects the client to capture tokens.**

| | |
| --- | --- |
| **Control** | Application-scoped setting; HTTPS enforced before a token is attached |
| **Implementation** | `missionApimpossible.endpoint` is `scope: application`, so a cloned repository **cannot** override it via workspace settings. Python and the extension both validate the scheme before sending. |
| **Residual risk** | **LOW.** A user who manually configures a hostile endpoint will send a token to it. |
| **Verification** | Attempt a workspace-level override; confirm it is not honored. Configure an `http://` endpoint; confirm refusal. |

---

## T17 — Public network exposure

**Management surfaces are reachable.**

| | |
| --- | --- |
| **Control** | Private pattern disables public access on APIM and Foundry; no all-API subscription; built-in subscription suspended |
| **Implementation** | AzAPI closure after PE creation, with a single owner for the property |
| **Residual risk** | **MEDIUM.** APIM Private Link covers the **gateway**, not every management surface. Bastion's endpoint is public. The public pattern is public by definition. |
| **Verification** | Confirm public gateway access fails after closure; confirm repeated `terraform apply` does not reopen it. |

---

## T18 — Local proxy loopback listener ⚠️

**A local process abuses the Entra proxy to obtain inference as the developer.**

Applies **only** when the local Entra proxy is running (`docs/local-proxy.md`).
Goal 1 on its own does not create this exposure.

The proxy exists so IDEs that only understand API keys can use the gateway. It
presents a key-shaped surface on loopback and forwards the developer's real
Entra token. While it runs, it is a process holding a live token, reachable
from the machine it runs on.

| | |
| --- | --- |
| **Control** | IPv4 loopback binding; random local key; constant-time comparison; restrictive file permissions on every file that holds it |
| **Implementation** | Binds `127.0.0.1` explicitly — never `0.0.0.0`, and never the name `localhost`, which can resolve to `::1` and produce a confusing mismatch. Only `POST /v1/responses` and `GET /v1/models` are served. The key **is persisted**, at `%LOCALAPPDATA%\mission-apimpossible\proxy.key` and inside the IDE's model configuration, because a key that changed every start would have to be re-pasted every start — and a tool that demands that is one people disable. Every file holding it is created with owner-only permissions (`0600` on POSIX via `O_CREAT`, never write-then-chmod; inheritance stripped via `icacls` on Windows), and a failure to apply them raises rather than warns. It is never logged. |
| **Residual risk** | **MEDIUM.** Any process running as this user can reach the listener while it is up. The secret raises the bar — an attacker must also read it from the IDE's storage or the proxy's output — but it does not eliminate the risk. Malware already executing as the developer can impersonate the IDE and spend that developer's quota under their identity. |
| **Verification** | Confirm the listener is unreachable from another host on the network; confirm a wrong or absent key is rejected; confirm the key appears in no log and no telemetry; confirm every file holding it is readable only by the owner (`icacls` / `stat -c %a`); confirm the listener is gone once the process exits. |

**Why this is accepted.** The alternative is that the gateway cannot be used
from an IDE at all. The exposure is bounded to a single machine, requires local
code execution to exploit, and grants nothing that the developer could not
already do themselves — an attacker with code execution as the developer could
equally run `az login` and call the gateway directly. What it does change is
that they need not prompt for sign-in.

**What it does not weaken.** Attribution is unaffected: the token is the
developer's own, so `tid:oid` in telemetry still resolves to the human, and the
per-user token limits still key on them. This is a courier, not an identity
substitution — see `docs/local-proxy.md` for why that distinction is load
bearing and why this is an explicit, recorded exception to the "no
authentication shim" rule rather than a reinterpretation of it.

---

## T19 — Authenticated but unauthorised caller

**Anyone the identity provider will issue a token to can use the gateway.**

Found by security review, and the most serious issue this design has had.

Authentication establishes *who you are*. Authorisation establishes *whether
you may*. An earlier version of this gateway did only the first, and in
`brokered` mode that is a privilege escalation: the gateway calls the model
with its own managed identity, so whoever the policy admits gets inference.

The gap was subtle because the audience looked correct. `api_audience` was the
Foundry resource — a Microsoft **first-party** resource. Entra issues tokens
for those to any authenticated principal; issuance is not gated by RBAC on the
model. So every member and B2B guest of the tenant could run `az login`, obtain
a valid token, and get inference they held no permission for, billed to the
subscription, under a fresh quota counter.

The client-application allowlist did not help. It filters **applications**, and
the entries it holds — Azure CLI, VS Code — are public first-party clients
every tenant user already has. It also failed open when empty.

| | |
| --- | --- |
| **Control** | Dedicated Entra application with user assignment required, plus a positive scope check in policy |
| **Implementation** | `api_audience` is a dedicated app registration (`api://<app-id>`), not a first-party resource. Its enterprise application sets `appRoleAssignmentRequired = true`, so **Entra itself refuses a token** to anyone not explicitly assigned. The policy then requires `scp` to contain `required_scope`, matching whole space-delimited entries so a longer scope name cannot satisfy a shorter one. A Terraform precondition fails the apply if `identity_mode = "brokered"` and `required_scope` is empty. |
| **Residual risk** | **LOW.** Two independent layers, one at the identity provider and one at the gateway. Assignment is now an explicit administrative act. Residual: whoever manages that assignment list controls access, so it belongs under the same review as any other entitlement. |
| **Verification** | Request a token for the old Foundry audience and confirm the gateway returns `401`; request one for the gateway audience as an assigned user and confirm `200`; remove the assignment and confirm Entra refuses to issue at all. Proven live: old audience `401 invalid_token`, new audience `200`. |

> **Why `passthrough` never had this problem.** There, the caller's own token
> reaches Foundry, which performs its own RBAC check — the second, independent
> authorisation decision that `brokered` mode removes. Brokered mode eliminates
> the direct-backend bypass (T11) and must replace that lost check with one of
> its own. It now does.

---

## Summary

| Threat | Public | Private |
| --- | --- | --- |
| T1 Stolen token | HIGH | HIGH |
| T2 Wrong tenant | LOW | LOW |
| T3 App-only token | MEDIUM | MEDIUM |
| T4 Header spoofing | LOW | LOW |
| T5 Correlation injection | LOW | LOW |
| T6 Model enumeration | LOW | LOW |
| T7 Denial of wallet | MEDIUM | MEDIUM |
| T8 Telemetry leakage | MEDIUM* | MEDIUM* |
| T9 Response persistence | MEDIUM | MEDIUM |
| T10 Unapproved features | LOW | LOW |
| **T11 Backend bypass** | **HIGH (accepted)** | **LOW (unverified)** |
| T12 Excessive RBAC | MEDIUM | MEDIUM |
| T13 State exposure | LOW–MEDIUM | LOW–MEDIUM |
| T14 Jumpbox | n/a | MEDIUM (G4 open) |
| T15 Supply chain | MEDIUM | MEDIUM |
| T16 Endpoint config | LOW | LOW |
| T17 Public exposure | MEDIUM | MEDIUM |
| **T18 Loopback listener** | **MEDIUM (only while the proxy runs)** | **MEDIUM (only while the proxy runs)** |
| **T19 Unauthorised caller** | **LOW (was HIGH)** | **LOW (was HIGH)** |

\* Until the canary verification is performed against a live deployment.

**No threat above has been verified against a running deployment.** All
verification steps are pending — tracked as `map-p13`.
