# Security policy

## Reporting a vulnerability

Do **not** open a public issue for a security vulnerability.

Report privately through GitHub's
[private vulnerability reporting](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability)
on this repository.

Please include: affected component, reproduction steps, impact, and whether a
deployed environment is affected. We will acknowledge receipt and keep you
updated.

## Scope

This is a **reference implementation**, not a managed service. It is intended
to be read, reviewed, and adapted — not deployed unexamined into production.

In scope:

- APIM policy that fails to enforce a documented control
- Terraform that stores a reusable authentication secret in state
- Any path that logs prompts, model output, or credentials
- A bypass of the private pattern's anti-bypass network controls
- Client code that leaks, persists, or mishandles a token

Out of scope:

- Anything already documented as a **residual risk** in
  [`docs/threat-model.md`](docs/threat-model.md) — for example, the public
  pattern's direct-backend bypass, which is intentional and stated
- Azure platform vulnerabilities (report to Microsoft via MSRC)
- The approximate nature of token quotas, which is documented platform
  behavior

## Known unresolved items

These are published rather than hidden. Reporting them again is not necessary,
though additional analysis is welcome:

| Item | Status |
| --- | --- |
| **Gate G4** — Windows jumpbox cannot be GA-only, passwordless, and secret-free simultaneously | Unresolved; fails closed |
| Public pattern permits direct Foundry access | Accepted, documented |
| Token quotas are approximate, not billing controls | Documented platform behavior |
| Correlation chain ends at the gateway boundary | Documented limitation |

See [`docs/platform-validation.md`](docs/platform-validation.md) for the full
list with evidence.

## Deployment status

This repository has been **validated offline but never deployed**. No control
has been empirically verified against a running environment. Treat every
security property as *designed* rather than *proven* until you have verified it
in your own tenant.

## Supported versions

The `main` branch only. Pinned dependency versions are recorded in
[`docs/deployment.md`](docs/deployment.md).
