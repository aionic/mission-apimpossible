![Mission APIMpossible — same identity, all the way through](docs/images/mission-apimpossible.png)

# Mission APIMpossible

**Your developers use AI coding models with their own identity. No API keys. No shared secrets. Every request attributable to a person.**

Most AI gateway samples put a key in front of the model. This one doesn't have
a key to put anywhere.

---

## The problem this solves

A developer opens their IDE and asks a model to review some code. Three
questions follow, and most architectures answer at least one of them badly:

| Question | The usual answer | The answer here |
| --- | --- | --- |
| **Who made this request?** | A shared service principal, or an API key someone pasted into a settings file | The developer, by name, on every request |
| **What did they send?** | Unknown — or worse, logged somewhere | Never logged. Proven, with canaries |
| **What happens when they leave?** | Rotate a key, hope you found every copy | Their Entra account is disabled. Done |

An API key is a bearer credential with no identity attached. It can be copied
into a chat message, committed to a repository, or inherited by whoever takes
over a laptop. It survives the person who created it, and it tells your audit
log nothing useful.

This sample removes it entirely.

## How it works

```
Developer's IDE ──their Entra token──▶ API Management ──▶ Azure AI Foundry ──▶ Model
                                        │
                                        ├─ Is this a real person in our tenant?
                                        ├─ Is this request allowed?
                                        ├─ Are they within their quota?
                                        └─ Log who and when. Never what.
```

API Management is the control point. It verifies the human, enforces what a
request may contain, applies per-person limits, and records the identity — then
calls the model. The developer's prompt is never written to any log.

**And it works with the tools developers already use.** GitHub Copilot expects
an API key; it has no concept of signing in to Entra. A small local proxy
bridges that: the IDE gets the key-shaped interface it wants, while the request
leaving the machine carries the developer's real identity. Copilot agent mode,
tool calling included, runs against your own governed model.

## What is proven, not asserted

Every claim below was tested against a live deployment. Where something could
not be proven, it says so.

| Claim | Evidence |
| --- | --- |
| A real person's identity reaches the model | Telemetry attributes every request to the developer's object ID |
| Prompts are never logged | Canary phrases absent from all telemetry — checked alongside a record count, because an empty search proves nothing if logging is broken |
| No key exists in the path | Local key auth disabled on the model at creation; no subscription keys issued |
| Developers cannot bypass the gateway | Direct call to the model returns `401` even for an authorized user; through the gateway returns `200` |
| Nothing sensitive is stored in infrastructure state | 23 resources audited field by field, zero findings |
| It works in a real IDE | GitHub Copilot agent mode, tool calling, against a Foundry model |

Full evidence, including what remains unproven, is in
[platform validation](docs/platform-validation.md).

## What it costs

API Management Standard v2 is the significant line item at roughly **$0.95 per
hour** — about **$700 a month** if left running. Model usage is billed
separately by Azure.

This is a reference deployment. Stand it up, demonstrate it, tear it down.
`azd down` removes everything.

## Try it

You need an Azure subscription, permission to create resources and assign
roles, and quota for a supported model.

```powershell
git clone <this repository>
cd mission-apimpossible

azd env new map-public
azd env set DEPLOYMENT_PROFILE public
# fill in subscription, tenant, region, and model in infra/profiles/public.tfvars
azd up
```

Then, from Python:

```powershell
. .\scripts\use-environment.ps1
uv run python examples/python/respond.py "Review this function for races."
```

There is no API key to configure. There is no key.

To use it from GitHub Copilot:

```powershell
uv run python -m map_proxy
```

That writes your VS Code configuration and prints nothing you need to copy.
Reload the window and pick the model in Chat.

Step-by-step instructions, including the private network variant, are in
[deployment](docs/deployment.md).

## Two patterns

| | **Public** | **Private** |
| --- | --- | --- |
| Gateway reachable from | The internet, with a valid Entra token | Your network only |
| Model reachable from | The gateway | The gateway only — enforced by network rules |
| Use it for | Demonstrations, evaluation | Production adoption |
| Roughly | $0.95/hr | $1.30/hr plus jumpbox |

Both are deployed and destroyed independently. See
[architecture](docs/architecture.md).

## Honest limitations

Stated here rather than buried, because a reference sample that oversells
itself is worse than none.

- **Quotas are safeguards, not billing controls.** Token limits are enforced
  per person, but a burst can overshoot them. Azure Cost Management remains the
  financial source of truth.
- **The audit trail ends at the gateway.** You can prove who called and when.
  Correlating that to Azure OpenAI's own internal logs is not something this
  sample can establish.
- **Disabling response storage is not the same as disabling all retention.**
  Azure's own abuse-monitoring is a separate matter, governed by your agreement
  with Microsoft.
- **Secure Windows test access is unresolved.** The passwordless options
  available today conflict with the "no secrets in state" rule this sample
  holds itself to. It fails closed rather than quietly compromising.

## Documentation

**Start here**

| | |
| --- | --- |
| [Architecture](docs/architecture.md) | How it fits together, and the identity boundaries |
| [Deployment](docs/deployment.md) | Standing it up, both patterns, and tearing it down |
| [Local proxy](docs/local-proxy.md) | Using the gateway from Copilot and other IDEs |

**For reviewers**

| | |
| --- | --- |
| [Security](docs/security.md) | Controls, and the limit of each one |
| [Threat model](docs/threat-model.md) | Threat → control → residual risk |
| [Platform validation](docs/platform-validation.md) | The evidence, and what is still unproven |

**For implementers**

| | |
| --- | --- |
| [API contract](docs/api-contract.md) | What is allowed, what is rejected, and why |
| [Observability](docs/observability.md) | What is recorded, and what deliberately is not |
| [Enterprise adoption](docs/enterprise-adoption.md) | Taking this into a real environment |

## Contributing

```powershell
.\scripts\validate-policies.ps1        # gateway policy and security invariants
uv run pytest                          # Python and contract tests
cd src\vscode; npm test                # extension tests
terraform -chdir=infra validate        # infrastructure
.\scripts\prepublication-check.ps1     # secrets, identifiers, stale claims
```

See [SECURITY.md](SECURITY.md) to report a vulnerability.

## License

MIT. See [LICENSE](LICENSE).
