# Private test access — jumpbox and Bastion

> **Gate G4 is unresolved.** Read this before setting
> `acknowledge_unresolved_g4 = true`. The module deliberately fails closed
> until you do.

## What this provides

`enable_test_access = true` (the default for the private pattern) provisions a
**Windows jumpbox** and **Azure Bastion** inside the private VNet, so the
private path can be exercised without corporate VPN or ExpressRoute.

The jumpbox runs VS Code and the Python client natively, from inside the
network boundary. It exists to demonstrate two things:

1. Your Entra identity **can** reach the model through the gateway.
2. The same identity **cannot** reach the model directly — despite holding
   `Cognitive Services OpenAI User`.

(2) is the point. A private endpoint alone would not stop it.

## The conflict

Three agreed requirements cannot all hold today:

| Requirement | Conflicting documented behavior |
| --- | --- |
| **GA features only** | Entra RDP through the Bastion **portal** is in **public preview**. Only Entra **SSH** in the portal is GA. |
| **Passwordless sign-in** | Native-client Entra RDP (`--enable-mfa`) **prompts for a password** after MFA, and requires the connecting PC to be Entra joined to the same directory. |
| **No reusable secret in Terraform state** | `azurerm_windows_virtual_machine` documents that the administrator password **is stored in state as plain text**. |

Sources: [Bastion Entra authentication](https://learn.microsoft.com/azure/bastion/bastion-entra-id-authentication),
[AzureRM Windows VM](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/windows_virtual_machine).

## What this repository does about it

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

## Your options

### A. Accept the documented limitations *(what the flag acknowledges)*

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

### B. Accept preview portal RDP

Connect through the Azure portal with **Microsoft Entra ID (Preview)**. This is
genuinely passwordless.

- ✅ Passwordless
- ❌ **Preview** — contradicts the GA-only decision
- ⚠️ Not available in every region

### C. Linux jumpbox instead

Entra SSH is **GA and passwordless**.

- ✅ GA
- ✅ Passwordless
- ❌ No native VS Code desktop on the jumpbox (Remote-SSH from your workstation
  instead, which requires network access to the VM — partly defeating the
  point of a self-contained test host)

This option was explicitly declined during planning, but it remains the
cleanest resolution if the Windows requirement softens.

### D. No jumpbox at all

```hcl
enable_test_access = false
```

Use existing VPN or ExpressRoute plus DNS forwarding. See
[`enterprise-adoption.md`](enterprise-adoption.md).

- ✅ No conflict, no extra cost
- ❌ Requires existing corporate connectivity

## Enabling it

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

## Cost

| Resource | Note |
| --- | --- |
| Azure Bastion | **Bills from deployment**, regardless of use |
| Windows VM | Deallocating reduces but does not eliminate charges |
| Public IP (Bastion) | Standard SKU, static |
| Managed disk | Premium SSD, billed while it exists |

Set `enable_test_access = false` when you are not actively testing.

## Security properties

| Property | Implementation |
| --- | --- |
| No public IP on the VM | NIC has no public IP configuration |
| RDP only via Bastion | NSG allows 3389 only from the Bastion subnet |
| Entra sign-in | `AADLoginForWindows` extension |
| Least privilege | `Virtual Machine User Login`, **not** Administrator Login |
| **Cannot reach the model directly** | Foundry PE NSG denies `snet-jump`; jumpbox NSG mirrors on egress |
| No inference via VM identity | The VM's managed identity holds no Cognitive Services role |
| No session recording | Deliberately disabled — a recording would capture source code on screen |

### Residual risks

- A **bootstrap local account** exists until Entra sign-in is confirmed
  healthy. Disabling it before that would risk locking everyone out.
- **Source code persists on the VM disk.** Treat the jumpbox as holding the
  same data classification as a workstation.
- **Bastion's endpoint is public.** "Private" describes the inference data
  plane, not every management surface.

## Verifying the point of it all

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

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Entra option missing in portal | Bastion SKU below Standard, extension not provisioned, or region lacks the preview |
| Native RDP rejects sign-in | Connecting PC not Entra joined to the same directory |
| Gateway call fails from the VM | DNS not resolving the private zone, or APIM PE NSG rules |
| Direct model call **succeeds** | **Anti-bypass regression** — check `private_endpoint_network_policies` is enabled, without which the NSG is not evaluated |
| Bootstrap account still enabled | Entra sign-in not confirmed healthy; check `C:\ProgramData\MissionAPIMpossible\bootstrap.log` |
