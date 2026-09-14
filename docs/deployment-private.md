# Deploying the private pattern

The pattern that actually prevents the direct-backend bypass.

Everything from [`deployment-public.md`](deployment-public.md) applies —
prerequisites, choosing a model, observing the token audience. This document
covers only what differs.

## What differs

| | Public | Private |
| --- | --- | --- |
| APIM ingress | Public | Private endpoint, public disabled |
| Foundry ingress | Public | Private endpoint, public disabled |
| Gateway → model | Public network | Outbound VNet integration |
| Direct bypass | Possible | **NSG-denied** |
| Test access | Your workstation | Optional jumpbox + Bastion |
| Cost | Higher | Higher still |

## Additional prerequisites

- Non-overlapping address space (default `10.42.0.0/16`)
- **Either** existing VPN/ExpressRoute + DNS forwarding, **or**
  `enable_test_access = true`
- A decision on [gate G4](private-test-access.md) if using the jumpbox
- Region supporting APIM Standard v2, **both** private endpoint types, and
  private-endpoint NSG enforcement

## Configure

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
acknowledge_unresolved_g4   = true          # read private-test-access.md first
jumpbox_admin_principal_ids = ["<your-object-id>"]
```

### Understanding `corporate_address_prefixes`

It does **two** things:

1. Allows those ranges to reach the APIM gateway private endpoint.
2. **Explicitly denies** them direct access to the Foundry private endpoint.

(2) is the security control. Private endpoints are reachable over peering,
VPN, and ExpressRoute under the default `AllowVNetInBound` rule, so without an
explicit deny, anyone on the corporate network bypasses the gateway — and they
will have valid RBAC to do it.

Leave it empty **only** if no such connectivity exists.

## Deploy

```powershell
azd env new map-private
azd up
```

### What happens, and why the order matters

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

## Verify — the test that matters

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

### Also test the bypass by IP

DNS is not a security control. Confirm a manual override still fails:

```powershell
$ip = (Resolve-DnsName <foundry-account>.openai.azure.com).IPAddress
curl.exe -i --max-time 15 --resolve "<foundry-account>.openai.azure.com:443:$ip" `
  https://<foundry-account>.openai.azure.com/openai/v1/responses
```

### And from the corporate network

If `corporate_address_prefixes` is set, repeat test (2) from a machine on that
network. The jumpbox test alone does not prove the corporate deny rule works.

## Without the jumpbox

```hcl
enable_test_access = false
```

Then you need:

- existing VPN or ExpressRoute to the VNet;
- DNS forwarding for `privatelink.azure-api.net` and
  `privatelink.openai.azure.com`;
- confirmation that `corporate_address_prefixes` covers your source ranges.

See [`enterprise-adoption.md`](enterprise-adoption.md).

## Tear down

```powershell
azd down --purge
```

Destroys the VNet, private endpoints, DNS zones, jumpbox, and Bastion. It does
**not** touch VPN/ExpressRoute or centrally owned DNS zones — the sample never
created them.

> An `azapi_update_resource` destruction does not revert its property change.
> That is fine here because teardown removes the whole service.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Gateway unreachable from jumpbox | DNS not resolving the private zone; check the zone VNet link |
| Gateway unreachable from corporate | `corporate_address_prefixes` missing your range |
| **Direct model call succeeds** | **Regression.** Check `private_endpoint_network_policies = "NetworkSecurityGroupEnabled"` and NSG rule priorities |
| APIM provisioning fails | Integration subnet not delegated to `Microsoft.Web/serverFarms`, or smaller than `/27` |
| Public access re-enabled after apply | Two owners for the property — the AzureRM resource must ignore it |
| Bastion Entra option missing | SKU below Standard, or extension not provisioned. See [gate G4](private-test-access.md) |
| Terraform fails on `acknowledge_unresolved_g4` | Working as intended. Read [`private-test-access.md`](private-test-access.md) |
