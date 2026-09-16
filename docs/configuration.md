# Configuration

Every setting, what it does, and when to change it.

Values live in `infra/profiles/<profile>.tfvars`. Copy the `.example` file and
fill it in; the examples carry the same defaults documented here.

Two settings have **no safe default** and Terraform refuses to deploy without
them: `api_audience` and `required_scope`. Both are explained under
[Identity](#identity).

---

## Quick reference

| Setting | Default | Change it when |
| --- | --- | --- |
| `identity_mode` | `brokered` | You want Foundry to authorise each caller itself |
| `api_audience` | *(none)* | Always — from `create-gateway-app.ps1` |
| `required_scope` | `Responses.Invoke` | You renamed the scope |
| `allowed_client_app_ids` | `[]` | You want to restrict which client applications may call |
| `model_capacity` | *(none)* | Your team grows — this is the shared ceiling |
| `tokens_per_minute` | `1000000` | A single developer needs more burst |
| `daily_token_quota` | `50000000` | Sustained daily use exceeds it |
| `max_concurrent_requests_per_user` | `12` | Agents chain many parallel tool calls |
| `max_request_bytes` | `1048576` | Rarely — see [the warning](#size-limits) |
| `backend_timeout_seconds` | `300` | Long reasoning runs time out |
| `telemetry_sampling_percentage` | `100` | Telemetry volume becomes expensive |
| `log_retention_days` | `30` | Your retention policy differs |
| `enable_test_access` | `false` | You accept the unresolved G4 trade-off |

---

## Identity

### `api_audience` — **required**

The audience a caller's token must carry. Set it to `api://<app-id>` from
`scripts/create-gateway-app.ps1`.

> **Do not point this at the Foundry resource.** It is a Microsoft first-party
> resource, and Entra issues tokens for it to *any* authenticated principal —
> issuance is not gated by RBAC on the model. In `brokered` mode the gateway
> then calls the model with its own managed identity, so your entire tenant
> could use it. This was a real vulnerability here; see
> [T19](threat-model.md).

### `required_scope` — **required in brokered mode**

Scope value the token must carry, matched as a whole space-delimited entry.
Terraform refuses to deploy `identity_mode = "brokered"` with this empty.

### `identity_mode`

| Value | Who calls Foundry | Trade-off |
| --- | --- | --- |
| `brokered` *(default)* | The gateway's managed identity, carrying the human's `oid` as `user_security_context` | No human holds inference RBAC, so the direct-backend bypass is impossible. The gateway becomes the only authorisation decision. |
| `passthrough` | The caller's own token | Foundry independently authorises each human — a second, independent check. But anyone with that RBAC can call Foundry directly, bypassing every gateway control. |

See [architecture](architecture.md#identity-modes).

### `allowed_client_app_ids`

Client applications permitted to call. **Empty disables the check.**

This filters *applications*, not people — and the ones you are likely to list
(Azure CLI, VS Code) are public first-party clients every tenant user already
has. It is defence in depth, not an access control. `required_scope` and the
app assignment are what decide who may call.

### `inference_principal_ids`

Human principals granted `Cognitive Services OpenAI User`. Used **only** in
`passthrough` mode; a Terraform precondition rejects it in `brokered` mode,
because the two modes must not both hold inference RBAC.

---

## Model

### `model_capacity` — **the setting people get wrong**

The deployment's throughput, shared by everyone. Per-user limits are keyed on
`tid:oid` and do **not** scale with team size; this one does, and it is what
actually runs out.

Sizing from a measured agent turn of roughly 30,000 tokens, at ~60,000 TPM
sustained per active developer:

| Active developers | Capacity | Approx. shared TPM |
| --- | --- | --- |
| 1–2, evaluating | 100 | 100,000 |
| 5–10 | 500 | 500,000 |
| 25–50 | 1,000+ | 1,000,000+ |

"Active" means mid-request, not enrolled. Check quota before raising:

```powershell
az cognitiveservices usage list -l <region> `
  --query "[?contains(name.value,'<model>')].{name:name.localizedValue,used:currentValue,limit:limit}" -o table
```

### `model_name`, `model_version`, `model_sku`

Pin an exact GA version. `model_sku` affects data residency —
`GlobalStandard` routes globally, `DataZoneStandard` keeps processing within a
geography. Choose deliberately.

---

## Rate limits

All per-user, keyed on validated `tid:oid`. A caller cannot move themselves
onto another counter, and refreshing a token keeps the same one.

| Setting | Default | Notes |
| --- | --- | --- |
| `tokens_per_minute` | 1,000,000 | Roughly 30 agent turns a minute. Generous by design: the ceiling that matters is `model_capacity`. |
| `daily_token_quota` | 50,000,000 | Fixed UTC day, **not** a rolling window. Raise this before raising per-minute limits — a daily ceiling hit mid-afternoon is worse than a brief throttle. |
| `max_concurrent_requests_per_user` | 12 | Coarse, and it **overshoots**: the counter is per gateway node, so the real ceiling is this multiplied by node count. |

**These are safeguards, not billing controls.** A burst can exceed the
per-minute ceiling before the policy is aware of it, because with
`estimate-prompt-tokens="false"` the token limiter cannot pre-charge a request.
Azure Cost Management is the financial source of truth. See
[gate G5](platform-validation.md#g5--token-governance).

---

## Size limits

| Setting | Default | |
| --- | --- | --- |
| `max_request_bytes` | 1 MiB | Transport cap, enforced on bytes |

Schema-level bounds (in `specs/responses-request.schema.json`):

| Bound | Value | Measured basis |
| --- | --- | --- |
| `input` text | 768 KiB | ~138 KB per real agent turn |
| Message items | 1,000 | 8–10 per turn |
| `tools` | 256 | 88–90 per turn |
| Tool description | 32 KiB | 5,859 characters |
| `max_output_tokens` | 32,768 | 4,096 truncated real coding work |

> **Do not lower these.** They were measured from real IDE traffic, not chosen.
> The original conservative values — 64 KiB body, 48 KiB input, 40 messages,
> 4,096-character descriptions — rejected every GitHub Copilot request that
> reached them. Someone "hardening" the sample by tightening them would
> reintroduce a day of debugging.

> **Raising `max_request_bytes` beyond 1 MiB is untested.** 512 KiB is proven
> to pass; 1 MiB leaves headroom. APIM's documented ceilings conflict — 4 MB
> for `validate-content`, 100 KiB in the runtime-limits table, 2 MiB for v2
> buffered payloads — and exceeding what APIM can actually process produces a
> `5xx` that looks like a gateway fault rather than a clean rejection. If you
> need more, measure first with `scripts/probe-size-ceiling.ps1`.

---

## Behaviour

### `backend_timeout_seconds`

Seconds to wait for **response headers**, not for the full stream. Reasoning
models on a large context can be slow; 300 accommodates that. Streaming
duration is governed separately.

### `normalize_quota_status_to_429`

Whether to rewrite a daily-quota `403` as `429`. **Defaults to `false`, and
should stay there** until a documented, reliable signal distinguishes a
quota `403` from an authorisation `403`. Blanket-mapping would turn a genuine
permissions failure into a retry loop.

### `telemetry_sampling_percentage`

100 while proving correlation works. Lower it once volume becomes a cost.
Sampling never re-enables payload capture — that is off at every verbosity.

### `log_retention_days`

Log Analytics retention. Telemetry contains `tid`/`oid` as pseudonymous
identifiers, so this is a privacy setting as much as a cost one.

---

## Network — private pattern only

| Setting | Notes |
| --- | --- |
| `vnet_address_space` | Must not overlap anything you will peer with |
| `corporate_address_prefixes` | Ranges allowed to reach the **gateway**. They are explicitly denied to the model. |
| `enable_test_access` | Windows jumpbox and Bastion. Default `false` |
| `jumpbox_size`, `bastion_sku` | Only when test access is enabled |
| `acknowledge_unresolved_g4` | Must be set explicitly to enable the jumpbox |

> **`acknowledge_unresolved_g4` is a deliberate speed bump.** Passwordless
> Windows access cannot currently be GA-only, password-free, and secret-free at
> the same time. The module fails closed rather than quietly picking one to
> compromise. See [gate G4](platform-validation.md#g4--windows-jumpbox-access-unresolved).

---

## After changing anything

```powershell
terraform -chdir=infra apply -var-file="profiles/public.tfvars"
```

Policy changes take effect on apply, but **not instantly** — allow about 45
seconds before testing, or you will measure the previous policy and draw the
wrong conclusion.

Verify the controls still hold:

```powershell
.\scripts\verify-request-validation.ps1     # bounds fail closed
.\scripts\verify-token-governance.ps1       # rate limits enforce
.\scripts\audit-state-secrets.ps1           # no secrets in state
```
