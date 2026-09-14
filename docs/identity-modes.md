# Identity modes

The gateway supports two ways of authenticating to Foundry. They optimise for
different threat models, and **neither is universally correct**.

```hcl
identity_mode = "brokered"      # default
identity_mode = "passthrough"
```

## The problem both are solving

If a developer holds `Cognitive Services OpenAI User` on the Foundry resource
and can reach the endpoint, they can call the model directly and skip every
gateway control: no token limits, no model allowlist, no `store:false`
enforcement, no telemetry.

## `passthrough` — end-to-end human identity

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

## `brokered` — RBAC terminates at the gateway (default)

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

## ⚠️ Brokered mode has a precondition that is easy to miss

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

---

## Choosing

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

## A note on the original design

The source brief for this repository explicitly ruled brokered mode out:

> Do not replace the user's token with an APIM managed identity … unless a
> current Microsoft platform limitation makes this unavoidable.

No platform limitation forces it. Brokered mode is offered as a **deliberate
architectural alternative with a documented trade-off**, not as a silent
substitution — which is why the mode is explicit, the RBAC inversion is
enforced by a Terraform precondition, and the policy invariants are scoped per
mode rather than relaxed.
