# Architecture

Mission APIMpossible demonstrates one idea: **a developer's own Microsoft Entra
identity reaches the model, and Azure API Management governs that request
without ever becoming the caller.**

There is no Foundry Agent Service, no application backend, and no
authentication shim. The gateway does not mint a token, look up a key, or swap
in a managed identity. It validates the human, applies policy to the human, and
forwards the human's original bearer token to Foundry, which performs its own
RBAC check on that same principal.

```text
Entra authenticates Alice
        ↓
APIM validates Alice
        ↓
APIM applies policy to Alice
        ↓
Foundry receives Alice's token
        ↓
Foundry RBAC authorizes Alice
        ↓
model executes
```

## Two deployment patterns

The repository ships two independently deployable patterns. They share Terraform
modules, APIM policy, and client code, but have separate azd environments,
Terraform state, resource groups, and Azure resources. Deploying or destroying
one never touches the other.

| | `public` | `private` |
| --- | --- | --- |
| APIM ingress | Public HTTPS | Private endpoint, public access disabled |
| Foundry ingress | Public endpoint, Entra + RBAC | Private endpoint, public access disabled |
| APIM → Foundry | Public network | Outbound VNet integration |
| Direct Foundry bypass | **Possible** — accepted residual risk | **Blocked by NSG** |
| Test access | Your workstation | Optional Windows jumpbox + Bastion |
| Purpose | Easy public evaluation | Enterprise adoption baseline |

Neither pattern uses an API key, a client secret, an APIM subscription key, or a
managed identity for inference.

## Public pattern

![Public deployment pattern](architecture/mission-apimpossible-public.mmd)

Source: [`mission-apimpossible-public.mmd`](architecture/mission-apimpossible-public.mmd)

### Runtime flow

1. The developer signs in through the VS Code extension (built-in Microsoft
   authentication provider) or the Python CLI (`AzureCliCredential`). The client
   acquires an Entra access token for the configured Foundry scope.
2. The client generates a UUIDv4 `x-correlation-id` and a W3C `traceparent`,
   then calls `POST /openai/v1/responses` on the APIM gateway.
3. APIM establishes canonical correlation, validates the token against a single
   fixed tenant, extracts trusted `tid`/`oid` **from the validated token only**,
   and deletes any caller-supplied identity or gateway-metadata headers.
4. APIM validates content type and size, enforces the request schema allowlist,
   checks the model against the approved deployment, and rejects `store:true`
   (injecting `store:false` when the field is omitted).
5. APIM applies `llm-token-limit` keyed on `tid:oid` and emits token metrics
   with low-cardinality dimensions only.
6. APIM selects a credential-free backend and forwards the request with the
   **original, unmodified** `Authorization` header plus canonical correlation
   and W3C context.
7. Foundry authorizes the human through Entra RBAC and the model executes.
8. The response streams back as server-sent events without gateway buffering.
9. APIM captures Foundry's `apim-request-id`, emits a metadata-only trace, and
   returns `x-correlation-id` and `x-foundry-request-id` to the client.

### The bypass the public pattern does not solve

A developer who holds `Cognitive Services OpenAI User` on the Foundry resource
can call the public Foundry endpoint directly and skip every gateway control:
no token limits, no model allowlist, no `store:false` enforcement, no telemetry.

This is **stated, not hidden**. It is the reason the private pattern exists, and
it is recorded in [`threat-model.md`](threat-model.md) as an accepted residual
risk of the public sample.

## Private pattern

![Private deployment pattern](architecture/mission-apimpossible-private.mmd)

Source: [`mission-apimpossible-private.mmd`](architecture/mission-apimpossible-private.mmd)

### What actually blocks the bypass

A private endpoint is **not** sufficient. Private endpoints are reachable from
peered VNets, VPN, and ExpressRoute, and the default `AllowVNetInBound` NSG rule
permits that traffic. A developer on the corporate network with valid inference
RBAC would still get through.

DNS is not a boundary either — a developer can supply the hostname and address
manually.

The control that actually works is an explicit NSG on the Foundry
private-endpoint subnet, with private-endpoint network policies enabled:

| Rule | Source | Action |
| --- | --- | --- |
| Allow gateway egress | `snet-apim-integration` | **Allow** TCP 443 |
| Deny jumpbox | `snet-jump` | **Deny** TCP 443 |
| Deny corporate ranges | configured enterprise prefixes | **Deny** TCP 443 |
| Deny remainder | `VirtualNetwork` | **Deny** TCP 443 |

The jumpbox user holds valid inference RBAC and still cannot reach Foundry
directly. That is the proof the private pattern must demonstrate, and it is
recorded as a pending acceptance test in
[`platform-validation.md`](platform-validation.md) gate G8.

### Bootstrap ordering

APIM Standard v2 cannot be created with public access already disabled. The
sequence is therefore:

1. Create APIM with **no usable inference API** and a deny-all policy.
2. Create the private endpoint and link the private DNS zone.
3. Disable public network access.
4. Only then attach the working Responses API.

No usable inference endpoint is ever publicly exposed. This ordering was
explicitly approved; see [security](security.md).

### Optional test access

`enable_test_access` (default `true` in the private pattern) provisions a
Windows jumpbox and Azure Bastion so the private path can be exercised without
corporate connectivity. Bastion and the VM are a pair — the toggle controls
both.

Set it to `false` when you have existing VPN/ExpressRoute and DNS forwarding.
The sample never provisions VPN or ExpressRoute; see
[`enterprise-adoption.md`](enterprise-adoption.md).

> **Gate G4 is unresolved.** Portal Entra RDP is in preview, native-client Entra
> RDP prompts for a password, and the AzureRM Windows VM stores its administrator
> password in state. Until this is resolved, the jumpbox must not be described as
> complete. See [`deployment.md`](deployment.md).

## Identity boundaries

Three identities exist. Only one of them ever calls the model.

| Identity | Purpose | Inference permission |
| --- | --- | --- |
| **Developer (human)** | Calls the Responses API | `Cognitive Services OpenAI User` on the Foundry resource |
| APIM managed identity | Publishes telemetry | **None** |
| Jumpbox managed identity | Entra VM sign-in only | **None** |

The clients must not let an unrestricted credential chain silently select a
managed identity — this matters most on the jumpbox, where a VM identity is
present. The Python CLI therefore uses an explicit tenant-bound
`AzureCliCredential` rather than `DefaultAzureCredential`.

## What the correlation chain can and cannot prove

Supported and joinable:

```text
client x-correlation-id
    → APIM frontend request (W3C operation_Id)
        → APIM backend dependency
            → captured Foundry apim-request-id
```

**Not** established: that Foundry echoes `x-ms-client-request-id` anywhere
queryable, or that Foundry exposes internal spans that join this trace. The
Foundry request ID is a support handle for raising a case — not a joinable
trace segment. See gate G6.

## Deliberate omissions

| Omitted | Why |
| --- | --- |
| Semantic caching | Coding prompts carry proprietary source; cross-user cache hits are a data-isolation problem. Documented as a future option requiring its own threat model. |
| Tools, MCP, computer use, file inputs | Each adds external interaction or persistence. Added only through an explicit allowlist with a documented threat model. |
| `previous_response_id`, conversations, background mode | Require server-side state. The client keeps context locally. |
| Automatic retries of inference POSTs | `POST /responses` is not idempotent; a retry can duplicate inference, tokens, and cost. |
| Multi-region, failover | No requirement; would add cost and complexity without a stated availability target. |

---

## Identity modes

The gateway supports two ways of authenticating to Foundry. They optimise for
different threat models, and **neither is universally correct**.

```hcl
identity_mode = "brokered"      # default
identity_mode = "passthrough"
```

### The problem both are solving

If a developer holds `Cognitive Services OpenAI User` on the Foundry resource
and can reach the endpoint, they can call the model directly and skip every
gateway control: no token limits, no model allowlist, no `store:false`
enforcement, no telemetry.

### `passthrough` — end-to-end human identity

The developer's original `Authorization` header is forwarded byte-for-byte.
Foundry performs its **own** Entra RBAC check on that same human.

```text
Entra authenticates Alice → APIM validates Alice → APIM applies policy to Alice
    → Foundry receives Alice's token → Foundry RBAC authorizes Alice → model runs
```

Four independent checks on one identity. If gateway policy is misconfigured,
Foundry still refuses. Conditional Access and token lifetime apply at the model
boundary. Foundry's own resource logs name the real human.

**Cost:** the human holds inference RBAC, so the bypass is possible. Preventing
it requires network controls — and network controls are only as strong as the
rules nobody has edited.

### `brokered` — RBAC terminates at the gateway (default)

The human holds **no** RBAC. Only the gateway's managed identity does. APIM
replaces the caller's token with its own and carries the validated human `oid`
as `user_security_context`.

The bypass is eliminated **by capability**: a developer cannot call Foundry
from any network position — not over VPN, not over ExpressRoute, not by
resolving the hostname manually — because they have no permission, and no
network position confers one.

That is strictly stronger than an NSG rule.

`user_security_context` is not a workaround. Microsoft documents it for
*"application-mediated architecture … or AI gateway"* scenarios and recommends
passing `EndUserId` and `SourceIP` so SOC analysts can investigate AI alerts
that originate from a gateway. Verified accepted on the Responses API.

**Cost, stated plainly:**

- Foundry authenticates the **gateway**, not the human. The independent
  downstream authorization check is gone.
- Foundry resource logs attribute everything to one service principal.
- Conditional Access and token lifetime apply only at the gateway boundary.
- APIM becomes a **confused deputy**: a permanently privileged caller that will
  invoke the model for anyone its policy admits. A policy misconfiguration is
  no longer caught downstream — it *is* the security boundary.

---

### ⚠️ Brokered mode has a precondition that is easy to miss

**Removing the account-scope role is not sufficient.** The guarantee holds only
if *no other assignment* grants the human Cognitive Services data actions.

A role assigned at **subscription** or **management group** scope is inherited
by the Foundry account. Several Azure roles carry
`Microsoft.CognitiveServices/*` as a **dataAction** — a wildcard that covers the
Responses API.

This was found the hard way in this repository's own deployment:

| Role | Scope | dataActions | Grants inference? |
| --- | --- | --- | --- |
| `Owner` | subscription | *(none)* | **No** — Owner has no dataActions |
| `User Access Administrator` | `/` | *(none)* | No |
| **`Foundry User`** | **subscription** | **`Microsoft.CognitiveServices/*`** | **Yes** |

After switching to brokered mode the account showed **only** the gateway
identity, the gateway worked correctly, and the direct call **still
succeeded** — because of a pre-existing subscription-scope `Foundry User`
assignment. Everything looked right.

> A PIM `Owner` elevation does **not** grant inference. That is worth knowing,
> because it is the first thing people suspect.

Run this before trusting brokered mode:

```powershell
.\scripts\verify-brokered-identity.ps1 -PrincipalId <entra-object-id>
```

It enumerates inherited assignments, resolves each role definition, and fails
if any confers Cognitive Services data actions.

### Resolving it

[`scripts/rescope-foundry-user.ps1`](../scripts/rescope-foundry-user.ps1)
replaces one subscription-wide assignment with resource-group-scoped ones,
preserving access everywhere except the gateway's own resource group. It
creates the replacements **before** removing the broad grant, and prints the
restore command first.

Behaviour change to accept deliberately: a new AI account in a *new* resource
group no longer inherits access and must be granted explicitly. That is better
hygiene than a subscription-wide data-plane wildcard, but it is a change.

### Verified end to end

After re-scoping, with the same human identity and the same token:

```text
direct to Foundry    HTTP 401  BLOCKED - no RBAC
through the gateway  HTTP 200  WORKS
```

All 14 gateway security controls still pass. That is the whole argument in one
test: the bypass is closed by removing the permission, not by guarding the
network path.

---

### Choosing

| | `passthrough` | `brokered` |
| --- | --- | --- |
| Bypass risk | Network-controlled, or accepted | **Eliminated by capability**\* |
| Foundry authenticates | The human | The gateway |
| Independent checks on identity | 2 | 1 |
| Foundry logs attribute to | The human | One service principal |
| Conditional Access at model boundary | Applies | Does not |
| Needs private networking for anti-bypass | Yes | No |
| Standing privileged identity | None | Gateway holds inference rights |
| Blast radius of a policy mistake | Contained by Foundry RBAC | Total |

\* subject to the inherited-role precondition above.

**Choose `brokered`** when preventing the bypass matters more than downstream
attribution, or when you want that property without building private
networking. This is the default.

**Choose `passthrough`** when a security review requires the model boundary to
authenticate the real human, when Conditional Access must apply to inference
itself, or when you are unwilling to accept a standing privileged identity.

They compose with either network profile, so `private + passthrough` gives you
network-enforced anti-bypass *and* end-to-end identity — at the cost of the
full private topology.

---

### A note on the original design

The source brief for this repository explicitly ruled brokered mode out:

> Do not replace the user's token with an APIM managed identity … unless a
> current Microsoft platform limitation makes this unavoidable.

No platform limitation forces it. Brokered mode is offered as a **deliberate
architectural alternative with a documented trade-off**, not as a silent
substitution — which is why the mode is explicit, the RBAC inversion is
enforced by a Terraform precondition, and the policy invariants are scoped per
mode rather than relaxed.
