# Pinned versions

Pinning is a security control here, not a convenience. Provider behavior around
Terraform state contents (gate G9) and policy schema acceptance (gate G5) is
version-specific, so a floating version can silently invalidate the evidence
recorded in [`platform-validation.md`](platform-validation.md).

## Toolchain

| Tool | Pinned | Enforced by | Notes |
| --- | --- | --- | --- |
| Terraform | `~> 1.16` | `infra/providers.tf` | `1.11+` is a hard floor: AzAPI write-only `sensitive_body` requires it. |
| AzureRM provider | `~> 5.5` (locked **5.5.0**) | `infra/providers.tf` + `.terraform.lock.hcl` | State-read behavior audited at 5.5.0. |
| AzAPI provider | `~> 2.7` (locked **2.12.0**) | `infra/providers.tf` + `.terraform.lock.hcl` | Used only for the narrow exceptions listed below. |
| random provider | `~> 3.6` (locked **3.9.1**) | `infra/providers.tf` + `.terraform.lock.hcl` | Jumpbox bootstrap value only. |
| Azure Developer CLI | `>= 1.33.0` | `scripts/preflight.ps1` | Terraform integration is beta; accepted as tooling risk. |
| Azure CLI | `>= 2.86.0` | `scripts/preflight.ps1` | Provides the human credential for the Python client. |
| Node.js | `>= 20.0.0` | `src/vscode/package.json` | Extension build and test host. |
| Python | `>= 3.12` | `pyproject.toml` | Typed client and offline tests. |
| uv | `>= 0.8.0` | `scripts/preflight.ps1` | Resolves and locks Python dependencies. |
| VS Code | `>= 1.90.0` | `src/vscode/package.json` | Minimum with the authentication API surface used. |

Commit `.terraform.lock.hcl`. It is what makes the G9 state-behavior evidence
reproducible rather than a claim about whichever version happened to resolve.

### AzureRM 5.x schema notes

Verified against the installed provider schema, not from memory:

| Surface | Correct form in 5.5.0 |
| --- | --- |
| Diagnostic metrics | `enabled_metric { category = ... }`, not `metric { ... enabled = true }` |
| App Insights local auth | `local_authentication_enabled = false` |
| Private DNS VNet link | `private_dns_zone_id`, not `resource_group_name` + `private_dns_zone_name` |

## Azure API versions

| Surface | Version | Why |
| --- | --- | --- |
| APIM management | `2024-05-01` or later | Required for current v2-tier networking capabilities. |
| Azure OpenAI data plane | v1 (no `api-version`) | The GA v1 API is the whole point of the sample. |

## Narrow AzAPI exceptions

AzureRM is the default. AzAPI is used **only** where AzureRM would violate an
agreed contract, and each use is justified here:

| Exception | Reason | Gate |
| --- | --- | --- |
| Log Analytics workspace | AzureRM reads and stores workspace shared keys in state. | G9 |
| APIM public-access disablement | Must occur *after* the private endpoint exists; a post-create update resolves the ordering problem with a single owner for the property. | G8 |
| Built-in APIM subscription state | Disable the all-access subscription without calling `ListSecrets`. | G9 |
| Windows jumpbox (proposed) | Write-only `sensitive_body` keeps an ephemeral bootstrap password out of state. **Unproven — see G4.** | G4 |

An `azapi_update_resource` destruction does **not** revert its property changes.
Each patched property therefore has exactly one owner, and repeated applies must
be proven not to reopen access.

## Model and region

**Intentionally unpinned.** `infra/variables.tf` supplies no default for
`location`, `model_name`, `model_version`, `model_sku`, or `model_capacity`.
Deployment fails closed until an operator selects and records a tuple verified
against current availability, new-deployment eligibility, quota, and residency
requirements. See gate G11.
