# Enterprise adoption

This repository is a reference sample. Adopting it in an enterprise means
replacing several things the sample provides for convenience, and supplying
several it deliberately does not.

## What the sample does not provide

| Not provided | Why | Your responsibility |
| --- | --- | --- |
| VPN / ExpressRoute | Connectivity is an organizational asset, not a per-workload resource | Connect the VNet to your existing hub or transit |
| Corporate DNS forwarding | Depends on your resolver topology | Conditional forwarding to the private zones |
| Remote Terraform state | Must outlive and be owned separately from the workload | Entra-authenticated Azure Blob backend |
| Hub/firewall routing | Depends on your network architecture | UDRs, NVA inspection, SNAT decisions |
| Entra Conditional Access | Tenant-level policy | Device compliance, MFA, token protection |
| Cost governance | Subscription-level | Budgets, alerts, chargeback |

The sample **never** creates VPN or ExpressRoute. If you set
`enable_test_access = false`, existing connectivity becomes a prerequisite.

## Networking handover

### Address space

Provide a `vnet_address_space` that does not overlap anything routable. The
module splits a `/16` into `/24`s:

| Subnet | Purpose |
| --- | --- |
| `snet-apim-integration` | Delegated APIM egress (`/27` minimum, `/24` recommended) |
| `snet-pe-apim` | Gateway private endpoint |
| `snet-pe-openai` | Foundry private endpoint — **the anti-bypass boundary** |
| `snet-jump` | Optional jumpbox |
| `AzureBastionSubnet` | Optional Bastion |

### The rule your network team must understand

```hcl
corporate_address_prefixes = ["10.0.0.0/8", "172.16.0.0/12"]
```

Setting this does **two** things:

1. **Allows** those ranges to reach the APIM gateway private endpoint.
2. **Explicitly denies** them direct access to the Foundry private endpoint.

(2) is not optional. Private endpoints are reachable over peering, VPN, and
ExpressRoute under the default `AllowVNetInBound` rule, so without an explicit
deny, any developer on the corporate network bypasses the gateway entirely —
and they will have valid RBAC to do it.

> **If your network team removes or broadens these deny rules, the
> architecture's central security property is gone.** Flag this explicitly in
> your handover.

### DNS

Link `privatelink.azure-api.net` and `privatelink.openai.azure.com` to your
resolution VNets, or integrate with centrally owned zones. Corporate resolution
needs an Azure DNS Private Resolver or forwarder with conditional forwarding.

> DNS is **not** a security control. A developer can supply the hostname and
> address manually. The NSG rules are what enforce the boundary.

### Routing through an NVA

If traffic must traverse a firewall:

- enable private-endpoint **route policies**;
- write sufficiently specific UDRs — a generic `0.0.0.0/0` route does **not**
  override the PE route;
- verify return routing;
- **check SNAT behavior.** If the NVA SNATs traffic, corporate callers may
  become indistinguishable from allowed APIM traffic, silently defeating the
  source-based deny rules.

Also review Azure Virtual Network Manager **security admin rules**: an "Always
allow" rule bypasses NSG evaluation entirely.

## Terraform state

The sample uses protected local state. For shared environments:

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "mission-apimpossible"
    key                  = "private.tfstate"
    use_azuread_auth     = true   # not an access key or SAS
  }
}
```

- Use **Entra authentication**, not access keys or SAS tokens.
- Grant `Storage Blob Data Contributor` at container scope.
- The backend must be created and owned **separately** — a backend cannot
  bootstrap itself from resources in the state it initializes, and destroying
  the workload must not destroy the state store.

## Identity

### Deployment vs inference

These are different principals and must stay separate:

| Role | Principal | Permissions |
| --- | --- | --- |
| Provisioning | CI service principal (OIDC) or an operator | Resource + role-assignment write |
| **Inference** | **Named humans or an Entra group** | `Cognitive Services OpenAI User` on the account |
| APIM administration | Platform team | Azure RBAC on APIM |
| Monitoring | Ops team | Log Analytics reader |

`AZURE_PRINCIPAL_ID` resolves azd's *current* principal. It is **not**
automatically your developer group. Set `inference_principal_ids` explicitly —
preferably to a group object ID, so access is managed through group membership
rather than Terraform runs.

### Token audience (gate G1)

Before deploying, acquire a real token and confirm its `aud` claim, then pin
`api_audience` to what you observed. A `.default` scope string is **not** an
audience claim, and copying one from documentation is how this goes wrong.

### Client allowlist (gate G2)

Populate `allowed_client_app_ids` with the client applications you actually
permit. An empty list disables the check — acceptable for a first deployment,
but it should not survive into production.

## Conditional Access

The gateway cannot distinguish a stolen token from a legitimate one within its
validity window. That mitigation belongs at the identity layer:

- require MFA for the Foundry audience;
- require compliant or hybrid-joined devices;
- consider token protection (sender-constrained tokens);
- shorten token lifetimes where your tooling tolerates it;
- alert on sign-ins from unexpected locations.

## Cost

| Driver | Note |
| --- | --- |
| APIM Standard v2 | Material standing cost |
| Model tokens | Usually the largest variable cost |
| Azure Bastion | Bills from deployment, regardless of use |
| Jumpbox VM | Deallocating reduces but does not eliminate |
| Private endpoints | Per-endpoint hourly + data |
| Log Analytics | Per-GB ingestion; sampling reduces it |

Gateway quotas are **operational safeguards, not billing controls**. Set Azure
budgets and alerts — that is the actual financial control.

Deploying both patterns doubles the shared-service cost.

## Hardening beyond the sample

| Option | Trade-off |
| --- | --- |
| Custom RBAC role limited to `responses/*` | Narrower than the built-in role; must be proven not to break the call path |
| Customer-managed keys | Operational overhead of key lifecycle |
| Lower telemetry sampling | Cheaper, but breaks the guarantee that any correlation ID is findable |
| Azure Policy enforcement | Prevents drift; requires policy authoring |
| Resource locks | Prevents accidental deletion; complicates teardown |
| Multi-region | Only with a stated availability requirement |

## Before you go live

- [ ] Verify model GA status, region, **new-deployment eligibility**, quota, and residency
- [ ] Pin `api_audience` to an **observed** token audience
- [ ] Populate `allowed_client_app_ids`
- [ ] Set `inference_principal_ids` to a group, not individuals
- [ ] Configure remote state with Entra auth, owned separately
- [ ] Hand the `corporate_address_prefixes` deny rules to your network team **with the explanation above**
- [ ] **Prove the bypass fails** from the corporate network, not just the jumpbox
- [ ] Run the telemetry canary test
- [ ] Set Azure budgets and alerts
- [ ] Apply Conditional Access to the Foundry audience
- [ ] Decide gate G4 if using the jumpbox
- [ ] Review [`cyber-review.md`](cyber-review.md) with your security team
