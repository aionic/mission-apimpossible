# Deployment

Everything needed to stand this up, verify it, and take it down again.

Two patterns, deployed and destroyed independently:

| | **Public** | **Private** |
| --- | --- | --- |
| Gateway ingress | Internet, Entra token required | Private endpoint only |
| Model reachable from | The gateway | The gateway only, enforced by network rules |
| For | Demonstration, evaluation | Production adoption |
| Roughly | `$`0.95/hr | `$`1.30/hr, plus jumpbox if enabled |

Start with the public pattern. It exercises the whole identity path, and the
private pattern is the same thing with the network closed.

---

## Public pattern


The easier of the two. APIM and Foundry are publicly reachable, with Microsoft
Entra enforced and no keys anywhere.

> **Read this first.** The public pattern does **not** prevent a developer with
> inference RBAC from calling Foundry directly and bypassing every gateway
> control. That is an accepted, documented residual risk. If you need it
> prevented, use [`deployment.md`](deployment.md).

### Prerequisites

| Requirement | Minimum |
| --- | --- |
| Terraform | 1.16 |
| Azure CLI | 2.86 |
| azd | 1.33 |
| Python + uv | 3.12 / 0.8 |
| Azure permissions | Contributor + **User Access Administrator** (role assignments) |
| Entra | Ability to sign in interactively to the target tenant |

### Step 1 — Choose a model

This repository ships **no default region or model**, and deployment fails
closed without one. Model GA status, regional availability, eligibility for
*new* deployments, quota, and data residency are five separate checks.

```powershell
az cognitiveservices account list-skus --location <region> --kind OpenAI -o table
az cognitiveservices usage list --location <region> -o table
```

Confirm against
[availability](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure-region-availability)
and [lifecycle](https://learn.microsoft.com/azure/foundry/openai/concepts/model-retirements).

### Step 2 — Observe the token audience (gate G1)

`api_audience` must be the audience that actually appears in a token — not a
`.default` scope string copied from documentation.

```powershell
az login --tenant <tenant-id>
$token = az account get-access-token --scope "https://ai.azure.com/.default" --query accessToken -o tsv

# Decode the payload locally. Do not paste a token into a web decoder.
$payload = $token.Split('.')[1]
$payload = $payload.PadRight([int][Math]::Ceiling($payload.Length / 4) * 4, '=')
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) |
    ConvertFrom-Json |
    Select-Object aud, tid, appid, azp, scp, idtyp
```

Record `aud` → `api_audience`, and `appid`/`azp` → `allowed_client_app_ids`.

> Decode locally. Pasting a live token into an online decoder hands someone
> your identity.

### Step 3 — Configure

```powershell
Copy-Item infra\profiles\public.tfvars.example infra\profiles\public.tfvars
```

Fill in:

```hcl
subscription_id  = "..."
tenant_id        = "..."
location         = "eastus2"
api_audience     = "<observed in step 2>"

model_name            = "<verified in step 1>"
model_version         = "<exact version>"
model_deployment_name = "coding-model"
model_sku             = "GlobalStandard"
model_capacity        = 10

apim_publisher_email   = "team-alias@example.com"
inference_principal_ids = ["<your-entra-object-id>"]
allowed_client_app_ids  = ["<observed in step 2>"]
```

Find your object ID:

```powershell
az ad signed-in-user show --query id -o tsv
```

> `inference_principal_ids` is **not** automatically the principal running azd.
> Set it explicitly; a group object ID is preferable.

### Step 4 — Deploy

```powershell
az login --tenant <tenant-id>
azd auth login
azd env new map-public
azd up
```

Preflight runs first and fails closed on toolchain versions and policy
invariants.

APIM Standard v2 provisioning typically takes 30–45 minutes.

### Step 5 — Verify

```powershell
.\scripts\postprovision.ps1

$env:MAP_ENDPOINT  = "<MAP_RESPONSES_ENDPOINT>"
$env:MAP_MODEL     = "<MAP_MODEL_DEPLOYMENT>"
$env:MAP_TENANT_ID = "<your tenant>"

uv run python examples/python/respond.py "Say hello in five words."
```

Then confirm the controls actually fire —
[`examples/curl/negative-tests.md`](../examples/curl/negative-tests.md) has the
full set. At minimum:

```powershell
# store:true must be REJECTED
curl.exe -i -X POST $env:MAP_ENDPOINT `
  -H "Authorization: Bearer $(az account get-access-token --scope https://ai.azure.com/.default --query accessToken -o tsv)" `
  -H "Content-Type: application/json" `
  -d "{\"model\":\"$env:MAP_MODEL\",\"input\":\"hi\",\"store\":true}"
```

Expect `400 store_not_permitted`.

### Step 6 — Confirm telemetry is clean

```powershell
uv run python examples/python/respond.py "CANARY-e3f1a9-DO-NOT-LOG please echo nothing"
```

Wait ~5 minutes, then in Application Insights Logs:

```kusto
let canary = "CANARY-e3f1a9-DO-NOT-LOG";
union traces, requests, dependencies, exceptions, customEvents
| where timestamp > ago(1h)
| where * has canary
```

Expect **zero rows** — but first confirm telemetry arrived at all, or an empty
result proves only that ingestion is broken:

```kusto
traces | where timestamp > ago(1h) | where message == "responses.invocation" | take 5
```

### Step 7 — Observe the bypass

```powershell
$foundry = (azd env get-values --output json | ConvertFrom-Json).FOUNDRY_DIRECT_ENDPOINT
curl.exe -i -X POST "${foundry}openai/v1/responses" `
  -H "Authorization: Bearer $(az account get-access-token --scope https://ai.azure.com/.default --query accessToken -o tsv)" `
  -H "Content-Type: application/json" `
  -d "{\"model\":\"$env:MAP_MODEL\",\"input\":\"hi\",\"store\":true}"
```

This **succeeds** — with `store:true`, no quotas, and no telemetry. That is
exactly what bypassing the gateway costs you, and exactly why the private
pattern exists.

### Configure VS Code

Settings (User scope — the endpoint setting is application-scoped on purpose,
so a cloned repository cannot redirect your token):

```json
{
  "missionApimpossible.endpoint": "<MAP_RESPONSES_ENDPOINT>",
  "missionApimpossible.model": "<MAP_MODEL_DEPLOYMENT>",
  "missionApimpossible.tenantId": "<your tenant>"
}
```

Build and install:

```powershell
cd src\vscode
npm ci
npm run compile
npx @vscode/vsce package --no-dependencies

# Stable VS Code:
code --install-extension mission-apimpossible-1.0.0.vsix

# VS Code Insiders is a SEPARATE installation:
code-insiders --install-extension mission-apimpossible-1.0.0.vsix
```

> **If you run Insiders, use `code-insiders` for both steps.** Stable and
> Insiders keep separate extension directories *and* separate `settings.json`
> files. Installing with `code` while running Insiders looks like it worked —
> the CLI prints "successfully installed" — and the commands simply never
> appear in the palette, with no error anywhere to explain why. The settings
> below must also be set in the Insiders `settings.json`
> (`%APPDATA%\Code - Insiders\User\settings.json`), not the stable one.

Select code → **Mission APIMpossible: Ask about the current selection**.

### Tear down

```powershell
azd down --purge
```

`--purge` is important: soft-deleted Cognitive Services accounts hold the
custom subdomain and block redeploying under the same name.

### Troubleshooting

| Symptom | Cause |
| --- | --- |
| `401` | Token audience mismatch — re-run step 2 |
| `403 not_delegated_identity` | Using a service principal; sign in as a user |
| Commands missing from the palette | Installed with `code` while running Insiders. Reinstall with `code-insiders`. |
| `endpoint is not configured` in Insiders | Settings were set in the stable `settings.json`. Insiders uses its own. |
| `403 unapproved_client` | Client app not in `allowed_client_app_ids` |
| `403` from backend | Missing `Cognitive Services OpenAI User` on the account |
| `400 unapproved_model` | `MAP_MODEL` ≠ `model_deployment_name` |
| Provisioning fails on quota | Insufficient capacity in the region |
| Provisioning fails on role assignment | Need User Access Administrator |


---

## Private pattern


The pattern that actually prevents the direct-backend bypass.

Everything from [`deployment.md`](deployment.md) applies —
prerequisites, choosing a model, observing the token audience. This document
covers only what differs.

### What differs

| | Public | Private |
| --- | --- | --- |
| APIM ingress | Public | Private endpoint, public disabled |
| Foundry ingress | Public | Private endpoint, public disabled |
| Gateway → model | Public network | Outbound VNet integration |
| Direct bypass | Possible | **NSG-denied** |
| Test access | Your workstation | Optional jumpbox + Bastion |
| Cost | Higher | Higher still |

### Additional prerequisites

- Non-overlapping address space (default `10.42.0.0/16`)
- **Either** existing VPN/ExpressRoute + DNS forwarding, **or**
  `enable_test_access = true`
- A decision on [gate G4](deployment.md) if using the jumpbox
- Region supporting APIM Standard v2, **both** private endpoint types, and
  private-endpoint NSG enforcement

### Configure

```powershell
Copy-Item infra\profiles\private.tfvars.example infra\profiles\private.tfvars
```

Beyond the public settings:

```hcl
deployment_profile = "private"
vnet_address_space = "10.42.0.0/16"

# Corporate ranges that reach this VNet.
# These are ALLOWED to the gateway and explicitly DENIED to the model.
corporate_address_prefixes = ["10.0.0.0/8"]

enable_test_access          = true
acknowledge_unresolved_g4   = true          # read deployment.md first
jumpbox_admin_principal_ids = ["<your-object-id>"]
```

#### Understanding `corporate_address_prefixes`

It does **two** things:

1. Allows those ranges to reach the APIM gateway private endpoint.
2. **Explicitly denies** them direct access to the Foundry private endpoint.

(2) is the security control. Private endpoints are reachable over peering,
VPN, and ExpressRoute under the default `AllowVNetInBound` rule, so without an
explicit deny, anyone on the corporate network bypasses the gateway — and they
will have valid RBAC to do it.

Leave it empty **only** if no such connectivity exists.

### Deploy

```powershell
azd env new map-private
azd up
```

#### What happens, and why the order matters

APIM **cannot** be created with public access already disabled. Terraform
therefore:

1. Creates APIM with **no usable inference API** and a deny-all policy.
2. Creates private endpoints and links private DNS zones.
3. Disables public network access.
4. **Only then** attaches the working Responses API.

No usable inference endpoint is ever publicly exposed.

Public-access closure has exactly one owner — an `azapi_update_resource`, with
the AzureRM resource ignoring the property — so repeated applies cannot reopen
it. Verify that:

```powershell
azd provision        # second run
az apim show --name <apim-name> --resource-group <rg> --query publicNetworkAccess
```

Expect `Disabled`.

Expect 45–60 minutes for the full deployment.

### Verify — the test that matters

Connect to the jumpbox:

```powershell
az network bastion rdp `
  --name <bastion-name> `
  --resource-group <rg> `
  --target-resource-id <vm-resource-id> `
  --enable-mfa
```

Then, **on the jumpbox**:

```powershell
az login --tenant <tenant-id>

# 1. Through the gateway — MUST succeed
$env:MAP_ENDPOINT  = "<gateway endpoint>"
$env:MAP_MODEL     = "<deployment name>"
$env:MAP_TENANT_ID = "<tenant>"
uv run python examples\python\respond.py "hello"

# 2. Directly to the model — MUST fail
curl.exe -i --max-time 15 https://<foundry-account>.openai.azure.com/openai/v1/responses
```

| Result | Meaning |
| --- | --- |
| (1) ✅ and (2) ❌ | **Working as designed** |
| Both ✅ | **Anti-bypass regression.** Check `private_endpoint_network_policies` is enabled — without it the NSG is not evaluated for PE traffic at all |
| Both ❌ | Check DNS resolution, APIM PE NSG rules, and RBAC |

Your identity holds valid inference RBAC in **both** cases. The only difference
is network policy — which is precisely the property being demonstrated.

#### Also test the bypass by IP

DNS is not a security control. Confirm a manual override still fails:

```powershell
$ip = (Resolve-DnsName <foundry-account>.openai.azure.com).IPAddress
curl.exe -i --max-time 15 --resolve "<foundry-account>.openai.azure.com:443:$ip" `
  https://<foundry-account>.openai.azure.com/openai/v1/responses
```

#### And from the corporate network

If `corporate_address_prefixes` is set, repeat test (2) from a machine on that
network. The jumpbox test alone does not prove the corporate deny rule works.

### Without the jumpbox

```hcl
enable_test_access = false
```

Then you need:

- existing VPN or ExpressRoute to the VNet;
- DNS forwarding for `privatelink.azure-api.net` and
  `privatelink.openai.azure.com`;
- confirmation that `corporate_address_prefixes` covers your source ranges.

See [`enterprise-adoption.md`](enterprise-adoption.md).

### Tear down

```powershell
azd down --purge
```

Destroys the VNet, private endpoints, DNS zones, jumpbox, and Bastion. It does
**not** touch VPN/ExpressRoute or centrally owned DNS zones — the sample never
created them.

> An `azapi_update_resource` destruction does not revert its property change.
> That is fine here because teardown removes the whole service.

### Troubleshooting

| Symptom | Cause |
| --- | --- |
| Gateway unreachable from jumpbox | DNS not resolving the private zone; check the zone VNet link |
| Gateway unreachable from corporate | `corporate_address_prefixes` missing your range |
| **Direct model call succeeds** | **Regression.** Check `private_endpoint_network_policies = "NetworkSecurityGroupEnabled"` and NSG rule priorities |
| APIM provisioning fails | Integration subnet not delegated to `Microsoft.Web/serverFarms`, or smaller than `/27` |
| Public access re-enabled after apply | Two owners for the property — the AzureRM resource must ignore it |
| Bastion Entra option missing | SKU below Standard, or extension not provisioned. See [gate G4](deployment.md) |
| Terraform fails on `acknowledge_unresolved_g4` | Working as intended. Read [`deployment.md`](deployment.md) |


---

## Optional Windows test access


> **Gate G4 is unresolved.** Read this before setting
> `acknowledge_unresolved_g4 = true`. The module deliberately fails closed
> until you do.

### What this provides

`enable_test_access = true` (the default for the private pattern) provisions a
**Windows jumpbox** and **Azure Bastion** inside the private VNet, so the
private path can be exercised without corporate VPN or ExpressRoute.

The jumpbox runs VS Code and the Python client natively, from inside the
network boundary. It exists to demonstrate two things:

1. Your Entra identity **can** reach the model through the gateway.
2. The same identity **cannot** reach the model directly — despite holding
   `Cognitive Services OpenAI User`.

(2) is the point. A private endpoint alone would not stop it.

### The conflict

Three agreed requirements cannot all hold today:

| Requirement | Conflicting documented behavior |
| --- | --- |
| **GA features only** | Entra RDP through the Bastion **portal** is in **public preview**. Only Entra **SSH** in the portal is GA. |
| **Passwordless sign-in** | Native-client Entra RDP (`--enable-mfa`) **prompts for a password** after MFA, and requires the connecting PC to be Entra joined to the same directory. |
| **No reusable secret in Terraform state** | `azurerm_windows_virtual_machine` documents that the administrator password **is stored in state as plain text**. |

Sources: [Bastion Entra authentication](https://learn.microsoft.com/azure/bastion/bastion-entra-id-authentication),
[AzureRM Windows VM](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/windows_virtual_machine).

### What this repository does about it

**The state problem is addressed.** The jumpbox is created through
`azapi_resource` using **write-only** `sensitive_body`, so the bootstrap
password is sent to Azure and never persisted in state. The bootstrap account
is then disabled by guest configuration once Entra sign-in is confirmed
healthy.

> **This is unproven.** It has not been exercised against Azure. Create,
> refresh, repeated apply, and recreate behavior all need verification —
> tracked as `map-p13`.

**The GA and passwordless problems are not addressed.** They require a
decision.

### Your options

#### A. Accept the documented limitations *(what the flag acknowledges)*

Use native-client RDP over Bastion Standard. You get Entra authentication with
MFA and Conditional Access — and a password prompt after MFA.

```powershell
az network bastion rdp `
  --name <bastion-name> `
  --resource-group <rg> `
  --target-resource-id <vm-resource-id> `
  --enable-mfa
```

- ✅ GA connection path
- ❌ Not passwordless
- ⚠️ Requires the connecting PC to be Entra joined to the same directory

#### B. Accept preview portal RDP

Connect through the Azure portal with **Microsoft Entra ID (Preview)**. This is
genuinely passwordless.

- ✅ Passwordless
- ❌ **Preview** — contradicts the GA-only decision
- ⚠️ Not available in every region

#### C. Linux jumpbox instead

Entra SSH is **GA and passwordless**.

- ✅ GA
- ✅ Passwordless
- ❌ No native VS Code desktop on the jumpbox (Remote-SSH from your workstation
  instead, which requires network access to the VM — partly defeating the
  point of a self-contained test host)

This option was explicitly declined during planning, but it remains the
cleanest resolution if the Windows requirement softens.

#### D. No jumpbox at all

```hcl
enable_test_access = false
```

Use existing VPN or ExpressRoute plus DNS forwarding. See
[`enterprise-adoption.md`](enterprise-adoption.md).

- ✅ No conflict, no extra cost
- ❌ Requires existing corporate connectivity

### Enabling it

```hcl
enable_test_access        = true
acknowledge_unresolved_g4 = true   # deliberate, never defaulted

jumpbox_size                = "Standard_D4s_v5"
bastion_sku                 = "Standard"   # minimum for native client
jumpbox_admin_principal_ids = ["<your-entra-object-id>"]
```

Without the acknowledgement, `terraform apply` fails with an explanation
rather than quietly deploying something that does not meet the stated
requirements.

### Cost

| Resource | Note |
| --- | --- |
| Azure Bastion | **Bills from deployment**, regardless of use |
| Windows VM | Deallocating reduces but does not eliminate charges |
| Public IP (Bastion) | Standard SKU, static |
| Managed disk | Premium SSD, billed while it exists |

Set `enable_test_access = false` when you are not actively testing.

### Security properties

| Property | Implementation |
| --- | --- |
| No public IP on the VM | NIC has no public IP configuration |
| RDP only via Bastion | NSG allows 3389 only from the Bastion subnet |
| Entra sign-in | `AADLoginForWindows` extension |
| Least privilege | `Virtual Machine User Login`, **not** Administrator Login |
| **Cannot reach the model directly** | Foundry PE NSG denies `snet-jump`; jumpbox NSG mirrors on egress |
| No inference via VM identity | The VM's managed identity holds no Cognitive Services role |
| No session recording | Deliberately disabled — a recording would capture source code on screen |

#### Residual risks

- A **bootstrap local account** exists until Entra sign-in is confirmed
  healthy. Disabling it before that would risk locking everyone out.
- **Source code persists on the VM disk.** Treat the jumpbox as holding the
  same data classification as a workstation.
- **Bastion's endpoint is public.** "Private" describes the inference data
  plane, not every management surface.

### Verifying the point of it all

Once connected, run the test that justifies the whole private pattern:

```powershell
# 1. Through the gateway — MUST succeed
$env:MAP_ENDPOINT = "<gateway endpoint>"
$env:MAP_MODEL    = "<deployment name>"
az login --tenant <tenant-id>
uv run python examples\python\respond.py "hello"

# 2. Directly to the model — MUST fail
curl.exe -i https://<foundry-account>.openai.azure.com/openai/v1/responses
```

| Result | Meaning |
| --- | --- |
| (1) succeeds, (2) fails | ✅ Working as designed |
| Both succeed | ❌ **Anti-bypass control has regressed.** Report it. |
| Both fail | Check RBAC, DNS resolution, and NSG rules |

Your identity holds valid inference RBAC in both cases. The difference is
purely network policy — which is exactly the property being demonstrated.

### Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Entra option missing in portal | Bastion SKU below Standard, extension not provisioned, or region lacks the preview |
| Native RDP rejects sign-in | Connecting PC not Entra joined to the same directory |
| Gateway call fails from the VM | DNS not resolving the private zone, or APIM PE NSG rules |
| Direct model call **succeeds** | **Anti-bypass regression** — check `private_endpoint_network_policies` is enabled, without which the NSG is not evaluated |
| Bootstrap account still enabled | Entra sign-in not confirmed healthy; check `C:\ProgramData\MissionAPIMpossible\bootstrap.log` |


---

## Pinned versions


Pinning is a security control here, not a convenience. Provider behavior around
Terraform state contents (gate G9) and policy schema acceptance (gate G5) is
version-specific, so a floating version can silently invalidate the evidence
recorded in [`platform-validation.md`](platform-validation.md).

### Toolchain

| Tool | Pinned | Enforced by | Notes |
| --- | --- | --- | --- |
| Terraform | `~> 1.16` | `infra/providers.tf` | `1.11+` is a hard floor: AzAPI write-only `sensitive_body` requires it, and ephemeral resources require `1.10+`. |
| AzureRM provider | `~> 5.5` (locked **5.5.0**) | `infra/providers.tf` + `.terraform.lock.hcl` | State-read behavior audited at 5.5.0. |
| AzAPI provider | `~> 2.7` (locked **2.12.0**) | `infra/providers.tf` + `.terraform.lock.hcl` | Used only for the narrow exceptions listed below. |
| random provider | `~> 3.6` (locked **3.9.1**) | `infra/providers.tf` + `.terraform.lock.hcl` | `3.7+` needed for `ephemeral "random_password"`, which keeps the jumpbox bootstrap value out of state. |
| Azure Developer CLI | `>= 1.33.0` | `scripts/preflight.ps1` | Terraform integration is beta; accepted as tooling risk. |
| Azure CLI | `>= 2.86.0` | `scripts/preflight.ps1` | Provides the human credential for the Python client. |
| Node.js | `>= 20.0.0` | `src/vscode/package.json` | Extension build and test host. |
| Python | `>= 3.12` | `pyproject.toml` | Typed client and offline tests. |
| uv | `>= 0.8.0` | `scripts/preflight.ps1` | Resolves and locks Python dependencies. |
| VS Code | `>= 1.90.0` | `src/vscode/package.json` | Minimum with the authentication API surface used. |

Commit `.terraform.lock.hcl`. It is what makes the G9 state-behavior evidence
reproducible rather than a claim about whichever version happened to resolve.

#### AzureRM 5.x schema notes

Verified against the installed provider schema, not from memory:

| Surface | Correct form in 5.5.0 |
| --- | --- |
| Diagnostic metrics | `enabled_metric { category = ... }`, not `metric { ... enabled = true }` |
| App Insights local auth | `local_authentication_enabled = false` |
| Private DNS VNet link | `private_dns_zone_id`, not `resource_group_name` + `private_dns_zone_name` |

### Azure API versions

| Surface | Version | Why |
| --- | --- | --- |
| APIM management | `2024-05-01` or later | Required for current v2-tier networking capabilities. |
| Azure OpenAI data plane | v1 (no `api-version`) | The GA v1 API is the whole point of the sample. |

### Narrow AzAPI exceptions

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

### Model and region

**Intentionally unpinned.** `infra/variables.tf` supplies no default for
`location`, `model_name`, `model_version`, `model_sku`, or `model_capacity`.
Deployment fails closed until an operator selects and records a tuple verified
against current availability, new-deployment eligibility, quota, and residency
requirements. See gate G11.
