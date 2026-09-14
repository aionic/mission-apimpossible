# Mission APIMpossible implementation plan

## 1. Purpose and current state

Create a public, production-quality reference repository demonstrating human-identity-preserving coding inference through Azure API Management to the GA Azure OpenAI v1 Responses API. Terraform is the only infrastructure source of truth; Azure Developer CLI orchestrates deployment and teardown.

Source requirements: `C:\Users\anevico\Downloads\Mission APIMpossible – Secure Responses API Implementation Prompt.md`, including its 41 sections and 27 acceptance criteria.

Target: `D:\Git\mission-apimpossible`.

Current-state inspection found an empty directory, including no hidden project files, and no Git repository. There is no existing application, infrastructure, policy, dependency manifest, CI workflow, or test suite to preserve or extend. This is a greenfield implementation, not a migration. The source prompt was read in full.

Public documentation was researched on 2026-09-14. No live Azure claims, quota checks, identity tests, or deployments have been performed, and no Azure resources exist. Scaffolding proceeds under approval; provisioning does not.

Execution status lives in beads (`bd ready`, `bd show map-p01`), seeded by `scripts/seed-beads.ps1`. The workstream identifiers P01-P12 in section 6 map to beads issues `map-p01` through `map-p12` with the same dependency graph.

## 2. Confirmed scope and decisions

| Area | Confirmed decision |
| --- | --- |
| Delivery | Two independently deployable patterns: `public` and `private`, sharing Terraform modules and policy/client code. These supersede the prompt's `sample` and `enterprise` profile labels; enterprise adoption is based on the private pattern. |
| Deployment isolation | Separate azd environments, Terraform states, resource groups, APIM instances, OpenAI accounts/deployments, and telemetry resources. Either pattern can be created or destroyed without affecting the other. One invocation deploys the selected environment, not both automatically. |
| Private test access | Optional Windows jumpbox and Azure Bastion, enabled by default in the private demonstration through a parameter. The VM runs official VS Code and the Python client inside the private network. |
| Enterprise connectivity | Document VPN/ExpressRoute and corporate DNS integration as enterprise alternatives. Do not provision VPN/ExpressRoute in the sample. With test access disabled, an existing approved access path is a prerequisite. |
| Private bootstrap | Transient public APIM creation is accepted only with no usable inference API, followed by deny-all protection, private endpoint establishment, and public-access disablement before publishing the working private API. |
| IDE | Minimal TypeScript VS Code extension, not a full chat product. Existing official VS Code Microsoft authentication must work in the first release. Unsupported compatible IDE forks are explicitly documented, not silently given a different identity path. |
| Other clients | Python CLI using uv, azure-identity, and the standard OpenAI SDK; safe curl examples. |
| Azure selection | Standard v2 APIM baseline. No fixed subscription, region, coding model, model version, or budget yet. Select and approve a GA model/region/SKU/capacity tuple before deployment. |
| Tooling lifecycle | Pinned azd Terraform integration is accepted despite its documented beta label. Azure runtime features remain GA unless a separate exception is explicitly approved. |
| Token failures | Missing, invalid, expired, wrong-audience, and wrong-tenant tokens return 401. Authorization failures on a validated identity and backend RBAC denials return 403. This intentionally updates the prompt's wrong-tenant 403 expectation. |
| Quota failures | TPM returns 429. Normalize daily-quota exhaustion to 429 only when a documented, reliable policy-origin signal distinguishes it from authorization/backend 403s. Otherwise stop that normalization and request approval; do not blanket-map 403. |
| State | No reusable authentication secrets in state, saved plans, outputs, or logs. Telemetry identifiers/connection strings are permitted when not credentials. Narrow AzAPI exceptions are approved to avoid provider key reads. |
| State ownership | Protected local state is acceptable for both standalone demonstrations. Enterprise adaptation requires a separately owned, Entra-authenticated remote backend; no backend bootstrap stack is included. |
| Platform gaps | Present documented alternatives for explicit approval. Do not silently change identity, expose a public backend, add a shim, select a preview feature, or relax the state contract. |

### Provisional API defaults approved for planning

| Setting | Initial value and qualification |
| --- | --- |
| HTTP request limit | 64 KiB; enforce bytes, including malformed, chunked, and encoded-body cases. |
| Input/instructions limit | 48 KiB aggregate UTF-8 text, including locally supplied history. |
| Output bound | 4,096 `max_output_tokens`, reduced if required by the selected model. |
| Per-principal TPM | 20,000, keyed by validated `tid:oid`. |
| Per-principal daily quota | 100,000 tokens per UTC calendar day, not a rolling window. |
| Concurrency | 2 requests per user; prove the actual counter lifetime with streaming. Do not represent header-time concurrency as full-stream enforcement. |
| Backend timeout | 120 seconds to response headers; separately document SSE idle/total-duration behavior and cancellation. |
| Diagnostics | 100% sampling for correlation acceptance; configurable afterward. Request/response bodies remain disabled at every verbosity. |
| Input scope | Text string or bounded, explicitly validated text-only message history. |
| Persistence | Reject explicit `store:true`; inject Boolean `store:false` when omitted; reject null/string/ambiguous values. |

Quotas are approximate operational safeguards, not exact billing controls. Streaming usage may be estimated or missing. Azure billing/Cost Management remains the financial source of truth.

## 3. Non-negotiable architecture requirements

The runtime path remains developer -> APIM -> Azure OpenAI Responses -> approved coding model. The developer's original Foundry-audience bearer token is forwarded unchanged. APIM validates and governs the caller; Foundry independently authorizes that same delegated human principal.

Only `POST /openai/v1/responses` is exposed. No wildcard proxy, chat-completions endpoint, Assistants, Foundry Agent Service, model-list API, stored-response retrieval, `api-version` dependency, application backend, authentication shim, OBO, API key, client secret, or inference managed identity is introduced.

APIM and VM identities may exist strictly for telemetry and Windows Entra sign-in, respectively. They receive no Foundry inference permissions. The clients must not accidentally select VM managed identity through an unrestricted DefaultAzureCredential chain.

No prompt/source-code, output, token, tool-argument, file-content, user-name, email, or display-name logging is allowed. `tid` and `oid` are protected pseudonymous identifiers in access-controlled logs, never high-cardinality metric dimensions. `store:false` disables Responses storage, not necessarily service abuse-monitoring retention; documentation must distinguish these.

### Public pattern

Public HTTPS APIM and public OpenAI endpoint, both requiring Entra authentication and appropriate authorization. No runtime subscription key. Direct OpenAI access by an authorized developer remains possible and must be demonstrated and documented as an intentional public-sample limitation, not described as prevented.

### Private pattern

Private APIM gateway ingress plus Standard v2 outbound VNet integration, private OpenAI endpoint, public access disabled on both inference services, linked private DNS, and network controls that prevent direct OpenAI access even from the jumpbox or a connected corporate network.

Use separate subnets for APIM integration, APIM private endpoint, OpenAI private endpoint, the optional Windows jumpbox, and `AzureBastionSubnet`. Enable private-endpoint NSG policies where enforcement is required. Allow OpenAI endpoint TCP 443 from APIM integration addresses only, then explicitly deny other connected sources before default VNet allow rules. DNS alone is not a security boundary.

The optional Bastion management path may use a public Bastion endpoint; the jumpbox has no public IP and no public RDP. "Private" describes the inference data plane, not an assertion that every management endpoint is private. A private-only Bastion variant would require existing private connectivity and is outside the standalone default.

VPN/ExpressRoute, hub routing, DNS forwarding, source NAT, and central policy integration are documented adoption responsibilities. Bastion is an administrative/test-access service, never part of the inference request path.

Architecture Mermaid contracts for both patterns are implementation-phase deliverables, to be validated and reviewed before infrastructure implementation. This plan does not present an unvalidated diagram or approve final architecture artwork.

## 4. Platform evidence and mandatory feasibility gates

The distinctions below must be retained in `docs\platform-validation.md`: documented support, source-observed provider behavior, empirically proven behavior, and unresolved limitations.

| Gate | Evidence and limitation | Required implementation outcome |
| --- | --- | --- |
| G1: API, scope, and identity | Current v1 documentation uses `/openai/v1/responses`, no dated API version, and `https://ai.azure.com/.default`. Some REST reference authentication text still lists Cognitive Services scope. [S1-S3] | Use the requested AI scope initially. Prove its actual access-token audience and delegated claims with official VS Code and Azure CLI against the chosen resource; pin the matching APIM audience. Do not equate a `.default` scope string with JWT `aud`, or silently accept multiple audiences. |
| G2: Human-only authorization | `validate-azure-ad-token` supports a fixed tenant and validated output JWT. `tid`/`oid` alone do not distinguish human from service principal. [S4-S5] | Require trusted subject/tenant and an endpoint-appropriate delegated scope, enforce approved client application IDs, and reject app-only tokens. Validate `azp`/`appid` according to token version. Do not reject human tokens merely because `roles` exists. |
| G3: VS Code authentication | Public API supports `authentication.getSession`; built-in Microsoft provider source supports tenant-specific acquisition and has host compatibility constraints. [S6-S8] | Prove existing-session acquisition, tenant/account selection, consent/Conditional Access, refresh, sign-out, and cancellation in a pinned stable official VS Code version. Treat source-only knobs as compatibility gates, not universal extension API guarantees. |
| G4: Windows test access | Bastion portal Entra RDP is documented as public preview; native Entra RDP requires Standard+ and may prompt for a password. AzureRM Windows VM provisioning stores its admin password. AzAPI documents write-only `sensitive_body`. [S22-S25] | Default-on Windows/Bastion cannot be called complete until GA passwordless access and secret-free state are proven. Evaluate a pinned AzAPI VM with an ephemeral bootstrap password, no persistent Terraform password resource, and a disabled/bootstrap-only local account after Entra readiness. Prove refresh/update/recreate behavior. No preview, local-password login, Linux substitution, or disabled-by-default workaround without separate approval. |
| G5: Token policies | Current `llm-token-limit` and `llm-emit-token-metric` references explicitly support Responses and streaming, and place both policies inbound. TPM is 429; daily quota is 403; streamed counting is approximate. [S9-S10] | Validate pinned policy syntax on Standard v2, daily-quota origin mapping, per-user isolation, limits under concurrency, remaining headers, and missing usage. No chat-completions-only replacement or fabricated exact accounting. |
| G6: Correlation and SSE | W3C APIM diagnostics and nonbuffered forwarding are documented. Foundry `apim-request-id` is a troubleshooting identifier. There is no established guarantee that `x-ms-client-request-id` is queryable or that Foundry exposes internal W3C spans. [S3, S11-S13] | Prove client/APIM request/dependency correlation and Foundry ID capture. Record the exact downstream observability boundary. Prove SSE ordering and latency with both token policies enabled; preserve missing usage as unknown. |
| G7: Validation limits | Content-validation references and gateway-runtime tables describe differing size ceilings; v2 buffering limits are another constraint. Header deletion has platform exceptions. [S14-S15] | Retain the conservative 64 KiB cap until tested. Fail closed on unsupported encodings, duplicate JSON properties, and unknown features. Document immutable transport headers; do not promise removal of every header. |
| G8: Private networking | Standard v2 private ingress and outbound integration can coexist. Public APIM disablement follows PE creation. Private endpoints alone do not prevent bypass by authorized humans. [S16-S18] | Implement ordered, declarative bootstrap and closure with one Terraform owner per property; prove repeat applies never reopen inference. Test APIM success and direct OpenAI denial from public, jumpbox, and approved connected test networks. |
| G9: State and providers | AzureRM can read Log Analytics and APIM subscription keys. Disabled OpenAI local auth avoids initial account key reads in the researched provider. AzAPI output defaults and write-only semantics require explicit control. [S19-S20, S24-S25] | Pin audited provider versions, avoid key-reading resources, use explicit nonsecret exports, and inspect sanitized field-level state evidence without printing secrets. Handle/suspend the built-in APIM all-access subscription without reading keys. Test first apply, refresh, repeated apply, and destroy. |
| G10: Safe telemetry | APIM body capture can disrupt SSE. Foundry categories include RequestResponse and Trace; category names do not establish payload-free contents. [S12-S13, S21] | Disable all four APIM body-capture legs, enable only approved metadata headers, test automatic exception/request telemetry, and do not enable `allLogs`, RequestResponse, or unreviewed Trace categories. Activate resource logs only after schema/privacy proof. |
| G11: Deployment target | API GA, model GA, region availability, new-deployment eligibility, quotas, capacity, and processing residency are different checks. azd Terraform remains beta. [S1-S2, S19, S26] | Record approved subscription/tenant, model/version/SKU/capacity, region, lifecycle policy, costs, and licenses before provision. Establish fresh up/reapply/down evidence for each independent environment. |

G4 is a known unresolved compatibility conflict, not an approved preview exception. G1, G3, G5-G11 require empirical evidence that cannot be obtained from this empty workspace alone. Unavailable test identities, network access, or telemetry must be reported as blocked/not run, never as passing.

## 5. Proposed repository surfaces

Paths below are planned, not created:

```text
README.md
SECURITY.md
LICENSE
CHANGELOG.md
azure.yaml
pyproject.toml
uv.lock
.gitignore
.github\workflows\ci.yml
.github\workflows\integration.yml
.github\dependabot.yml
infra\main.tf
infra\providers.tf
infra\variables.tf
infra\outputs.tf
infra\main.tfvars.json
infra\profiles\public.tfvars
infra\profiles\private.tfvars
infra\modules\monitoring\
infra\modules\foundry\
infra\modules\gateway\
infra\modules\networking\
infra\modules\test-access\
policies\global.xml
policies\responses.xml
policies\fragments\authentication.xml
policies\fragments\correlation.xml
policies\fragments\security-headers.xml
policies\fragments\request-validation.xml
policies\fragments\token-governance.xml
policies\fragments\observability.xml
specs\responses.openapi.json
specs\responses-request.schema.json
specs\telemetry.schema.json
src\vscode\package.json
src\vscode\package-lock.json
src\vscode\tsconfig.json
src\vscode\src\extension.ts
src\vscode\src\authentication.ts
src\vscode\src\responses-client.ts
src\vscode\src\correlation.ts
examples\python\respond.py
examples\curl\
scripts\preflight.ps1
scripts\configure-environment.ps1
scripts\test-private-access.ps1
scripts\bootstrap-jumpbox.ps1
queries\correlation.kql
queries\user-activity.kql
queries\token-usage.kql
queries\failures.kql
queries\throttling.kql
queries\latency.kql
docs\platform-validation.md
docs\architecture.md
docs\architecture\mission-apimpossible-public.mmd
docs\architecture\mission-apimpossible-private.mmd
docs\deployment-public.md
docs\deployment-private.md
docs\private-test-access.md
docs\identity.md
docs\correlation.md
docs\observability.md
docs\security.md
docs\threat-model.md
docs\cyber-review.md
docs\enterprise-adoption.md
tests\unit\
tests\contract\
tests\policies\
tests\integration\
```

The root Terraform stack selects a validated `deployment_profile`; azd environment-to-Terraform binding must be exercised against the pinned azd release rather than assuming arbitrary tfvars files are auto-loaded. Profile examples and `main.tfvars.json` must have one consistent precedence scheme. Do not duplicate complete stacks or introduce Bicep/ARM-template IaC.

Guest software setup is allowed through Terraform-owned VM extensions and an idempotent, pinned bootstrap script. Hooks may check prerequisites or write nonsecret local configuration; they must not create/update cloud resources in place of Terraform.

## 6. Implementation work breakdown and dependencies

### P01 - Resolving platform and authentication gates

Review the 15 platform checks in source section 40 plus G1-G11 above. Populate the platform-validation ledger with source date, resource/API/provider version, finding, minimal test, result, and decision. Select candidate pinned toolchains and a GA model tuple without hard-coding a preview or an unavailable model.

Run documentation/local experiments first. Before billable experiments, identify the Azure environment, permissions, quotas, test users, costs, and cleanup scope. Use isolated resources only after approval.

Prioritize official VS Code token acquisition, same-human OpenAI authorization, llm-policy/SSE behavior, private APIM creation ordering, and Windows/Bastion passwordless access. Verify the least-privileged built-in inference role at OpenAI resource scope: current `Cognitive Services OpenAI User` includes Responses permissions but is broader than only POST Responses. Document this residual scope; evaluate a narrowly scoped custom role only as a separately proven hardening option.

Completion: critical gates have evidence or explicit blockers/approved exceptions. No unsupported capability is represented as solved.

### P02 - Defining contracts and reviewing the two architectures

Depends on P01.

Produce and validate separate public/private Mermaid contracts, show the unchanged human-token flow, distinguish telemetry and administrative identities, and mark private endpoints outside the PaaS resource itself. Show the optional VM/Bastion test path and direct-backend denial boundary in the private diagram. Obtain architecture review before infrastructure work; no final presentation image is required by this task.

Define the minimal native-shaped POST contract and telemetry/error schemas. Allow `model`, text input/history, `instructions`, Boolean `stream`, `store:false`, bounded `max_output_tokens`, and only explicitly supported reasoning/inference options. Validate nested roles, content types, enum values, lengths, depth, array counts, and additional properties. Accept temperature or similar settings only when supported by the approved model.

Reject tools/functions, computer use, MCP, hosted tools, tool results, background execution, file/image/audio references, URL-fetching input forms, saved prompt references, conversations, `previous_response_id`, preview opt-in headers, multi-agent execution, automatic compaction, and unknown new fields. Ordinary URLs inside text are inert text, not external fetching.

Local text history is supported without server state. Encrypted reasoning items are not required for the initial client; if cross-turn reasoning is later necessary, add only the validated stateless/encrypted schema through an explicit feature review, never stored response chaining.

Completion: approved schemas, status matrix, header policy, defaults, architecture contracts, and traceability to original acceptance criteria.

### P03 - Scaffolding the repository and repeatable local toolchain

Depends on P02.

Initialize the repository and planned layout without publishing to GitHub. Pin compatible supported Python/Node/VS Code/Terraform/provider/azd versions and commit dependency/provider lockfiles during the eventual implementation workflow. Establish strict TypeScript, typed Python, and a minimal existing-from-scaffold validation toolchain.

Configure uv, extension build/test/package scripts, Terraform tests, and XML/schema contract checks. Ignore all state, plans, `.azure` environments, tokens, local request transcripts, downloaded binaries, VSIX/build artifacts, and integration evidence containing sensitive metadata. Choose an appropriate public-sample license before publishing.

Completion: deterministic local install/build commands, repository instructions, and nonsecret configuration examples.

### P04 - Building shared Terraform resources and state-safe monitoring

Depends on P03 and relevant P01 gates.

Implement shared resource naming, validation, tags, provider registration prerequisites, OpenAI account/custom subdomain with local auth disabled at creation, one explicit model deployment, resource-scoped human/group RBAC, Log Analytics, workspace-based Application Insights, and APIM Standard v2.

Use AzureRM where compatible. Use narrowly justified AzAPI for resources that otherwise collect authentication keys, APIM post-PE property updates if necessary, built-in subscription suspension, and potentially write-only Windows bootstrap. Declare a single owner per resource/property and avoid perpetual drift or hidden destructive replacements.

Use APIM managed identity for Entra-authenticated telemetry ingestion only, with the minimum monitoring role on Application Insights. Disable telemetry local auth where supported. VM system identity exists only if required by Entra VM login. Never grant either identity model inference.

Keep API subscription requirements disabled and do not create products/all-API subscriptions. Remove unused sample APIs and protect administrative surfaces using v2-supported settings only; document unsupported classic-tier controls instead of deploying invalid knobs.

Completion: state-safe shared modules, explicit nonsecret outputs, provider compatibility evidence, and no implicit resource key reads.

### P05 - Implementing gateway policy and strict stateless enforcement

Depends on P03; deployed validation depends on P04.

Inbound sequence: establish canonical bounded GUID correlation; validate the fixed-tenant user JWT; authorize delegated scope/application and extract trusted identity; normalize application headers; enforce content/encoding/size bounds; validate the exact model and request schema; reject `store:true` and safely inject `false` on omission; enforce input/output/concurrency limits; select a credential-free backend; apply both LLM policies in their documented inbound placement; forward the unchanged Authorization with canonical correlation and supported W3C context.

Use operation-level exact routing and deliberate query/header allowlists. Treat caller metadata, including `x-user-id`, `x-object-id`, `x-tenant-id`, `x-foundry-request-id`, and gateway-prefixed values, as untrusted. Reject/remove unsupported application headers rather than pretending APIM supports arbitrary wildcard deletion. Retain required transport-header exceptions.

Use `preserveContent` only where needed for inbound validation/rewrite; never read or transform SSE bodies in outbound processing. Configure `buffer-response=false` and no APIM inference retries. Bound malicious correlation/trace values; validate W3C context and let supported diagnostics establish correct parent-child spans, not necessarily byte-identical span IDs.

Outbound captures the backend `apim-request-id` before any gateway header collision, returns `x-correlation-id` and sanitized `x-foundry-request-id`, and emits fixed-message metadata traces. On-error and early returns preserve correlation and standard error shape without raw LastError messages, backend bodies, internal URLs, resource identifiers, or token claims.

Map supported backend-unavailable/timeout cases to 502/503/504 and preserve meaningful backend RBAC/throttle distinctions. Do not replace a started SSE stream with JSON; record terminal SSE failure/incomplete status client-side and document gateway visibility limits.

Completion: positive/negative policy tests and a deployed minimal inference path with no identity substitution.

### P06 - Wiring the independent public azd deployment

Depends on P04 and P05.

Implement infrastructure-only `azure.yaml` with `infra.provider: terraform`, no app service entry, and the pinned environment-binding convention. Configure a public profile without private networking or test-access infrastructure.

Provide nonsecret preflight for tool versions, tenant/subscription alignment, deployment/RBAC permissions, providers, model quota/capacity, and role recipients. Do not assume the provisioning identity is the inference user. Use bounded control-plane readiness checks; do not automatically retry an accepted inference POST to wait for RBAC.

Demonstrate fresh `azd up`, nonsecret outputs consumed by clients, idempotent reapply, and `azd down`. Handle APIM/OpenAI soft deletion and name reuse explicitly; never purge unrelated/pre-existing resources.

Completion: public deployment independently usable and removable, with direct-backend bypass clearly marked as an intentional residual risk.

### P07 - Building the independent private deployment and optional test access

Depends on P06 and G4/G8/G9 approval/evidence.

Provision dedicated APIM integration subnet with required delegation and NSG, separate PE subnets, private DNS zones/links, endpoint NSG enforcement, and required egress/dependency rules. Build APIM without a usable API, establish deny-all policy and PE connectivity, then declaratively disable public ingress before attaching the working inference API. Foundry public access remains disabled; do not enable it as an RBAC/DNS troubleshooting workaround.

Implement `enable_test_access=true` for the private profile and false/not applicable for the public profile. This controls the Windows VM and Bastion as a pair, including their dedicated network/support resources. Permit parameterized VM image/size and a GA Bastion tier satisfying the finally approved authentication path; pin an eligible Windows image and review license requirements.

The VM has no public IP, uses least-privileged Virtual Machine User Login plus narrowly scoped Reader access, and receives AADLoginForWindows through Terraform. RDP is allowed only from the Bastion path. Testers have human inference RBAC, but the VM subnet is explicitly denied direct OpenAI PE access. Do not allow the VM's managed identity to become a model caller.

Resolve G4 before claiming standalone Windows testing. If an ephemeral bootstrap password is approved/proven, use write-only provider input, never `random_password` as a persistent resource or secret-bearing VM custom data. Verify account disabling/readiness and a separately authorized recovery path; no shared administrator credentials are documented or output.

Install official VS Code, Azure CLI, Python/uv, and required tooling through pinned, signature/hash-checked, idempotent guest configuration. Provide explicit outbound connectivity for Entra, software installation/updates, and required service dependencies; do not rely on implicit VM internet egress. Parameterize/review NAT or existing firewall routing rather than silently adding broad inbound exposure.

Disable Bastion session recording and avoid diagnostic screenshots/transcripts that can capture source or tokens. Document VM disk/local editor persistence as client-side data, with cleanup and access controls.

When `enable_test_access=false`, omit VM/Bastion/support-only resources and require existing VPN/ExpressRoute/approved connectivity and DNS forwarding. Do not manage adopters' shared network/state resources or destroy them during teardown.

Completion: official VS Code and Python on the Windows VM call private APIM successfully as the user; direct OpenAI fails from that VM despite valid user RBAC; public inference access fails; optional-access toggle and independent private teardown work.

### P08 - Implementing the official VS Code reference extension

Depends on P03, approved P02 contracts, and G3.

Provide a command to send an explicit user prompt and optionally selected text, with a clear consent boundary. Never upload the workspace automatically, execute suggested code, or apply edits without user action. Stream into a nonpersistent in-memory document or equivalent minimal view; reserve diagnostics for metadata, not generated text.

Use the existing built-in Microsoft authentication provider for the configured tenant/resource scope. Acquire through the provider for each operation/refresh lifecycle, handle account/session changes and consent denial, and keep tokens out of settings, files, logs, telemetry, clipboard, and extension-owned persistence. No extension-managed refresh-token store or custom login service.

Use the standard OpenAI SDK when its callback authentication, raw response headers, abort handling, and SSE behavior fit; otherwise use a small justified standards-compliant transport without changing the public API contract. Set SDK retries to zero, disable redirect-based credential forwarding, require a trusted HTTPS gateway origin in user-scoped configuration, and do not accept workspace-controlled endpoint changes silently.

Generate UUIDv4 correlation and real OpenTelemetry-compatible trace/span context per invocation. Surface correlation, trace, Foundry request ID, model, final/incomplete status, and available token counts, never the token. Bound local history, set `store:false`, and handle cancellation/disconnect/auth expiry without automatic inference replay.

Completion: real official VS Code authentication and streaming success in public and private demonstrations, plus extension-host tests and explicit compatibility notes for unsupported hosts.

### P09 - Implementing Python and curl reference clients

Depends on P03 and P02; deployed validation depends on P06/P07.

Implement `uv run python examples\python\respond.py "<prompt>"` with streaming/nonstreaming modes, native Responses calls, callable bearer-token refresh, `store:false`, correlation/W3C headers, safe errors, and raw response-header access. Prefer explicit tenant-bound AzureCliCredential for the human-only smoke test; do not let environment/workload/managed identity silently win, especially on the jumpbox.

Set OpenAI retries to zero; keep token acquisition retries separate from inference POST replay. Display only requested generated output and a metadata summary. If client-decoded user identifiers are displayed, label them non-authoritative; APIM's validated identity remains the authorization source.

Curl examples must not embed a live token, echo it, enable verbose HTTP output, or place it in process arguments/history where avoidable; use safe in-memory/stdin header/config handling. Warn that literal proprietary prompts in command arguments can enter shell history and provide an interactive/stdin alternative.

Completion: runnable clients with cancellation, refresh, error, and configuration-isolation coverage.

### P10 - Establishing observable, payload-free correlation

Depends on P04/P05 and real runtime evidence from P06.

Configure W3C diagnostics, custom token metrics with bounded model/environment/API/backend dimensions, safe header allowlists, zero body bytes on frontend/backend requests/responses, and approved sampling/retention. Validate inherited/global/API diagnostics and automatic telemetry so verbose mode cannot re-enable payload capture.

Define a versioned metadata event linking canonical correlation, W3C operation, APIM request ID, Foundry request ID when present, trusted tenant/object ID, deployment, status, streaming flag, and safe failure category. Join native telemetry for actual APIM/backend durations; do not label pre-stream timing as full inference duration.

Final usage is nullable and must identify reported versus estimated source. Prove any nonstreaming/streaming extraction or policy variables actually exist; do not invent token variables. A final SSE event might never arrive, and an HTTP 200 may contain an SSE error. Keep aggregate metrics, per-user request logs, and incomplete accounting distinct.

Implement all six requested KQL files against the actual emitted table/column schema. Correlation queries join safe trace metadata to APIM request/dependency records; downstream service-log joins are provided only when experimentally supported. Missing usage must not become zero; low-cardinality metrics cannot be presented as per-user usage.

Investigate URL/query-string and automatic exception leakage, including rejected requests. If a platform telemetry path cannot be sanitized, disable that path where possible and document the resulting visibility gap instead of weakening the privacy promise.

Completion: operators can reconstruct supported request identity/correlation/failure/latency evidence without source, output, or credential leakage; unobservable downstream spans/accounting gaps are explicit.

### P11 - Implementing automated validation and guarded CI

Depends on P03 for scaffolding; completion depends on P05-P10.

Create targeted unit, schema, XML/policy contract, extension-host, Terraform, and client transport tests. Add only a minimal justified testing toolchain because none exists today. Establish CI once these commands exist; reuse them instead of introducing redundant scanners/runners.

PR CI is read-only/offline by default: deterministic dependency install, TypeScript build/tests, Python tests, XML/schema checks, Terraform format/validate/mock tests, policy invariants, dependency/secret scanning, and package assembly. Pin workflow actions and use least permissions. Never grant untrusted PRs Azure credentials or print state/plan contents.

Live integration is opt-in, environment-approved, scoped to explicitly owned disposable resources, and cost-bounded. OIDC deployment identity may provision resources but must never masquerade as the human inference test user. Delegated user tests require secure interactive/test-runner session handling; do not store refresh tokens in GitHub secrets. Private tests run from the approved private test host/network, not by reopening endpoints to hosted runners.

Use synthetic canaries and synthetic credentials in local transport/policy harnesses; no token echo service receives live user tokens. In-memory test comparisons may prove unchanged header forwarding without emitting credential values. Live evidence separately proves Foundry authorization and correlation; a test double is not proof of undocumented downstream logging.

Completion: the acceptance matrix below passes with evidence, or each unavailable check is explicitly blocked. Authentication/streaming/privacy defects block release.

### P12 - Producing review artifacts and proving lifecycle completion

Depends on P06-P11.

Write the README with the requested identity/correlation-first architecture introduction and clear side-by-side public/private setup. Explain selected-environment `azd up/down`, optional Windows/Bastion cost and switch, official VS Code sign-in, model/quota prerequisites, and enterprise VPN/ExpressRoute substitution.

Complete security, threat-model, identity, correlation, observability, cyber-review, deployment, private-access, and enterprise-adoption documents. Threats include every source-prompt item plus app-token confusion, local VM persistence, Bastion access/recording, endpoint-config token exfiltration, default APIM subscriptions, preview exposure, and provider-computed state secrets.

Use `Threat | Control | Implementation | Residual risk | Verification` and `Control | Implementation | Evidence | Residual risk` tables. Separate deployment permissions, APIM administration, monitoring access, VM login, and model inference. Explain abuse monitoring versus Responses persistence, public bypass, private anti-bypass enforcement, approximate quotas, sampling, and missing streamed usage.

Add operating/incident guidance, dependencies/supply-chain controls, supported versions, model lifecycle, cost drivers, cleanup/recovery, and known limitations. Do not advertise private Windows testing or GA-only completion until G4 is resolved.

Run clean public and private lifecycles independently, repeat applies, optional VM/Bastion disablement, and teardown of one while confirming the other is unaffected. Review repository contents for secrets before any public publication. Publishing to GitHub, marketplace publication, and committing changes are separate actions, not authorized by this plan alone.

Completion: all original acceptance criteria, with the explicitly approved revisions, are traceable to persistent code/configuration and evidence.

## 7. Acceptance and evidence matrix

| Area | Required evidence |
| --- | --- |
| Deployment | Fresh public and private `azd up`, no manual portal configuration, deterministic nonsecret outputs, reapply without drift, independent `azd down`, optional test-access on/off. Covers original 1 and 27. |
| Human identity | Real official VS Code user session and CLI user token; valid user succeeds; missing/expired/invalid/wrong-audience/wrong-tenant fails 401; app-only and unapproved app fail; no Foundry RBAC fails 403. Verify role recipients and no inference roles on APIM/VM identities. Covers 2, 4-6, 10-12. |
| Token preservation | Policy/transport harness with synthetic tokens proves exact Authorization preservation; live same-user Foundry authorization corroborates runtime wiring. No credentials appear in evidence. |
| Stateless schema | Explicit true, null, string false, duplicate keys, previous response ID, unknown/nested features, tools/URLs/files/background/preview headers rejected; omission forwarded as false; safe text history accepted; unsupported deployment rejected. Covers 7-8. |
| Bounds and isolation | Byte boundaries, missing Content-Length, chunking, compression, malformed UTF-8/JSON, aggregate history size, output cap, concurrency, TPM and daily quota. Two users isolated; refreshed tokens for one user retain one counter. Covers 9 and 24. |
| Error contract | Sanitized errors and correlation on every feasible success/error path; reliable daily-quota normalization only; no backend URL or internal error leak. Early-return and backend-error paths tested independently. |
| Streaming | Events arrive before completion, no whole-response buffering, preserved order, available headers, cancellation, disconnect, incomplete usage, SSE errors under HTTP 200, and no inference replay. Covers 13 and 18. |
| Correlation | Valid UUID preserved, invalid/missing/duplicate replaced safely; trusted response metadata overwrites spoofs; APIM request/dependency share the trace; Foundry request ID linked. Prove outgoing header via gateway diagnostics/test harness, not an invented Foundry echo. Covers 3 and 14-17. |
| Token telemetry | Observed aggregate metrics and per-user logs reconcile only where usage is available; reported/estimated/missing distinguished. No invented billing-grade or aborted-stream counts. Covers 18. |
| Privacy | Canary source and generated-output markers, Authorization patterns, and sensitive malformed inputs absent from all configured telemetry/exception paths, including increased verbosity. Confirm telemetry arrival first; an empty result caused by missing ingestion is not a pass. Covers 19-21 and 24. |
| Key/state safety | OpenAI local auth disabled; no API/subscription key needed; no client secret or persistent VM password in state/plans/outputs/logs; telemetry identifiers explicitly classified; default APIM subscription safely disabled. Covers 22-23. |
| Private bypass | APIM succeeds from Windows VM; direct OpenAI fails from VM with valid user token, public host, and available connected corporate test host; forced hostname/IP resolution cannot bypass NSG rules. VM has no public RDP. |
| Windows access | GA passwordless Bastion/Windows sign-in proven or separately approved exception; normal user can run official VS Code; guest setup/update/recovery works without stored bootstrap credentials or inference MI fallback. |
| Documentation | Complete threat and cyber-control matrices with source/evidence links, known limits, public versus private residual risks, roles, and lifecycle instructions. Covers 25-26. |

Full comparison of correlation at a managed Foundry service boundary or exact streamed usage may be unavailable. If so, document the evidence boundary and request an acceptance amendment; do not silently mark the corresponding original criterion satisfied.

## 8. Operational and quality considerations

Reliability: single-region reference deployments, no invented availability SLA or automatic inference failover. Distinguish safe control-plane polling from non-idempotent inference retries. Specify backend-header timeout separately from stream lifecycle.

Security: authenticate before trusting claims, enforce delegated user identity, separate administration and inference, deny external execution/stateful features, protect telemetry/state and guest disks, enforce network anti-bypass, and refuse silent capability fallbacks.

Cost: Standard v2 has material standing cost; two deployments double shared-service instances. Bastion charges while provisioned even when idle; VM deallocation does not remove all costs. Account for private endpoints, explicit egress, telemetry, and model usage. No cheaper tier is promised until all required policies/networking are proven.

Operations: Terraform remains authoritative; bootstrap ordering, state ownership, provider upgrades, resource soft deletion, DNS, and guest recovery are documented. Sample local state is private/restricted; shared enterprise state uses Entra-backed access and a separately managed lifecycle.

Performance: preserve SSE, bounded validation, output limits, token-bucket/streaming estimation caveats, first-event versus full-duration measurements, and no semantic caching. Never trade away privacy by inspecting/logging model bodies for telemetry.

## 9. Research sources

Links record planning evidence, not proof of a deployment. Reconfirm volatile claims against the pinned implementation versions.

- S1: [Azure OpenAI v1 lifecycle, authentication, and SDK refresh](https://learn.microsoft.com/azure/foundry/openai/api-version-lifecycle).
- S2: [Responses API, supported models/regions, stateless/encrypted reasoning](https://learn.microsoft.com/azure/foundry/openai/how-to/responses).
- S3: [Responses REST schema and troubleshooting response headers](https://learn.microsoft.com/rest/api/microsoft-foundry/azureopenai/responses).
- S4: [APIM validate-azure-ad-token](https://learn.microsoft.com/azure/api-management/validate-azure-ad-token-policy).
- S5: [Entra claim validation](https://learn.microsoft.com/entra/identity-platform/claims-validation), [token claim meanings](https://learn.microsoft.com/entra/identity-platform/access-token-claims-reference), and [OpenAI User built-in role](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/ai-machine-learning#cognitive-services-openai-user).
- S6: [VS Code authentication API](https://code.visualstudio.com/api/references/vscode-api#authentication).
- S7: [VS Code Microsoft provider tenant/scope handling: ScopeData](https://github.com/microsoft/vscode/blob/main/extensions/microsoft-authentication/src/common/scopeData.ts).
- S8: [Microsoft provider client compatibility: isSupportedClient](https://github.com/microsoft/vscode/blob/main/extensions/microsoft-authentication/src/common/env.ts).
- S9: [llm-token-limit](https://learn.microsoft.com/azure/api-management/llm-token-limit-policy).
- S10: [llm-emit-token-metric](https://learn.microsoft.com/azure/api-management/llm-emit-token-metric-policy).
- S11: [APIM forward-request](https://learn.microsoft.com/azure/api-management/forward-request-policy) and [W3C diagnostic configuration](https://learn.microsoft.com/rest/api/apimanagement/diagnostic/create-or-update?view=rest-apimanagement-2024-05-01).
- S12: [APIM server-sent events](https://learn.microsoft.com/azure/api-management/how-to-server-sent-events).
- S13: [APIM Application Insights integration and custom metrics](https://learn.microsoft.com/azure/api-management/api-management-howto-app-insights).
- S14: [APIM validate-content](https://learn.microsoft.com/azure/api-management/validate-content-policy) and [gateway runtime limits](https://learn.microsoft.com/azure/api-management/api-management-gateways-overview#gateway-runtime-limits).
- S15: [APIM header restrictions](https://learn.microsoft.com/azure/api-management/set-header-policy#limitations) and [error handling](https://learn.microsoft.com/azure/api-management/api-management-error-handling-policies).
- S16: [APIM networking combinations](https://learn.microsoft.com/azure/api-management/virtual-network-concepts), [private endpoints](https://learn.microsoft.com/azure/api-management/private-endpoint), and [outbound integration](https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound).
- S17: [APIM v2 capabilities and limitations](https://learn.microsoft.com/azure/api-management/v2-service-tiers-overview).
- S18: [Private endpoint network policies](https://learn.microsoft.com/azure/private-link/disable-private-endpoint-network-policy), [NSG defaults](https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview#default-security-rules), and [hybrid private DNS](https://learn.microsoft.com/azure/private-link/private-endpoint-dns-integration).
- S19: [azd Terraform integration](https://learn.microsoft.com/azure/developer/azure-developer-cli/use-terraform-for-azd), [azd schema](https://learn.microsoft.com/azure/developer/azure-developer-cli/azd-schema), and [Terraform AzureRM backend](https://developer.hashicorp.com/terraform/language/backend/azurerm).
- S20: [AzureRM provider source, v5.5.0](https://github.com/hashicorp/terraform-provider-azurerm/tree/v5.5.0/internal/services), [Terraform sensitive data](https://developer.hashicorp.com/terraform/language/manage-sensitive-data), and [APIM default subscriptions](https://learn.microsoft.com/azure/api-management/api-management-subscriptions).
- S21: [Cognitive Services diagnostic categories](https://learn.microsoft.com/azure/azure-monitor/reference/supported-logs/microsoft-cognitiveservices-accounts-logs).
- S22: [Bastion Entra authentication: GA/preview and password distinctions](https://learn.microsoft.com/azure/bastion/bastion-entra-id-authentication).
- S23: [Windows Entra VM sign-in](https://learn.microsoft.com/entra/identity/devices/howto-vm-sign-in-azure-ad-windows).
- S24: [AzureRM Windows VM state/password behavior](https://github.com/hashicorp/terraform-provider-azurerm/blob/v5.5.0/website/docs/r/windows_virtual_machine.html.markdown).
- S25: [AzAPI resource write-only sensitive_body and output export controls](https://github.com/Azure/terraform-provider-azapi/blob/main/docs/resources/resource.md). This source tracks main; pin and test a release before adopting the behavior.
- S26: [Model regional availability](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure-region-availability), [model lifecycle](https://learn.microsoft.com/azure/foundry/openai/concepts/model-retirements), and [quota](https://learn.microsoft.com/azure/foundry/openai/how-to/quota).

## 10. Approval boundary

The plan was approved for implementation with G4 explicitly unresolved and live deployment gates outstanding. Approval authorizes implementation of the agreed scope, not unannounced exceptions to same-human identity, GA runtime features, Windows passwordless access, privacy, or state security.

Scaffolding, code, policy, documentation, and offline tests proceed under that approval. The following require separate, explicit authorization and are **not** covered:

- creating any Azure resource, including `azd up`, `terraform apply`, and billable feasibility experiments;
- selecting and committing to a subscription, tenant, region, model, or capacity that incurs cost;
- publishing this repository, its VS Code extension, or any artifact to a public or internal registry;
- accepting a preview feature, a local-password fallback, or a relaxed state contract to unblock G4.

Before a paid deployment, resolve target/capacity/cost inputs and any relevant blocked gates.

No time or duration estimates are part of this plan. Execution status and task dependencies are tracked in beads as `map-p01` through `map-p12`.
