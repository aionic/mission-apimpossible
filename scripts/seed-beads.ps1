# Seeds the Mission APIMpossible workstreams into beads.
# Idempotent: skips issues that already exist.
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$issues = @(
    @{ Id = 'map-p01'; P = 0; Title = 'Resolving platform and authentication gates'
       Desc = 'Resolve gates G1-G11 from docs/implementation-plan.md. Highest risk items: official VS Code user-token acquisition for the Foundry audience, same-human Foundry authorization, APIM llm-* policy behavior against the Responses API, secret-free Terraform state, and GA passwordless Windows/Bastion sign-in. Record every finding in docs/platform-validation.md separating documented support, provider-source observation, empirical proof, and unresolved limitation. Stop any portion that lacks documented support and request approval.' }
    @{ Id = 'map-p02'; P = 0; Title = 'Defining contracts and architectures'
       Desc = 'Define the allowlisted Responses request schema, telemetry event schema, and error/status matrix. Produce and validate separate public and private Mermaid architecture contracts showing the unchanged human token, telemetry-only identities, private endpoints outside the PaaS resource, and the direct-backend denial boundary.' }
    @{ Id = 'map-p03'; P = 1; Title = 'Scaffolding the repository toolchain'
       Desc = 'Create the repository layout, pin Python/TypeScript/Terraform/azd toolchains, commit lockfiles, and establish local validation commands. Ignore all state, plans, tokens, transcripts, and evidence artifacts.' }
    @{ Id = 'map-p04'; P = 1; Title = 'Building shared Terraform resources'
       Desc = 'Implement the OpenAI account with custom subdomain and local auth disabled at creation, one explicit model deployment, resource-scoped human RBAC, Log Analytics, workspace-based Application Insights, and APIM Standard v2. Use narrowly justified AzAPI where AzureRM would read authentication keys into state. Grant no inference permissions to any managed identity.' }
    @{ Id = 'map-p05'; P = 1; Title = 'Implementing gateway security policies'
       Desc = 'Implement the inbound/outbound/on-error policy chain: canonical correlation, fixed-tenant delegated token validation, trusted identity extraction, spoofable header removal, size and schema validation, model allowlist, store=false enforcement, per-user token governance, unchanged Authorization forwarding, non-buffered SSE, Foundry request-ID capture, and sanitized errors.' }
    @{ Id = 'map-p06'; P = 2; Title = 'Wiring public azd deployment'
       Desc = 'Deliver the independently deployable public environment: infrastructure-only azure.yaml with the Terraform provider, nonsecret preflight checks, fresh azd up, idempotent reapply, and azd down. Document the direct-backend bypass as an intentional public-sample residual risk.' }
    @{ Id = 'map-p07'; P = 2; Title = 'Building private deployment and test access'
       Desc = 'Implement isolated private networking: dedicated APIM integration subnet, private endpoints for APIM and OpenAI, private DNS, and anti-bypass NSG rules that deny direct OpenAI access from the jumpbox and connected corporate networks. Add the parameterized default-on Windows VM and Bastion test access. Blocked on gate G4 until GA passwordless sign-in and secret-free bootstrap are proven.' }
    @{ Id = 'map-p08'; P = 2; Title = 'Implementing VS Code reference extension'
       Desc = 'Build the minimal official VS Code integration using the built-in Microsoft authentication provider for the configured tenant and Foundry scope. Explicit prompt/selection consent, unchanged user token, streaming output, session refresh, cancellation, metadata-only diagnostics, zero inference retries, and no token persistence.' }
    @{ Id = 'map-p09'; P = 2; Title = 'Implementing Python and curl clients'
       Desc = 'Implement the typed uv-managed Python Responses CLI using an explicit tenant-bound human credential, plus safe curl examples. Callable token refresh, stateless input, correlation and W3C headers, raw response-header access, zero inference retries, and no token echo.' }
    @{ Id = 'map-p10'; P = 2; Title = 'Establishing payload-free observability'
       Desc = 'Wire W3C correlation, Foundry request-ID capture, low-cardinality token metrics, protected per-user metadata logs, and the six KQL queries against the real emitted schema. Prove nullable usage handling and that no prompt, output, or credential reaches any telemetry path at any verbosity.' }
    @{ Id = 'map-p11'; P = 2; Title = 'Implementing validation and guarded CI'
       Desc = 'Implement offline unit, schema, policy-contract, Terraform, and extension tests plus opt-in live integration tests across both deployments. Keep the deployment OIDC identity distinct from the delegated human inference identity. Never report a skipped check as passing.' }
    @{ Id = 'map-p12'; P = 2; Title = 'Completing review artifacts and lifecycle'
       Desc = 'Complete the README, architecture, security, threat-model, cyber-review, observability, and enterprise-adoption documents. Prove independent clean deployment and teardown of both patterns, the optional test-access toggle, and a prepublication secret review.' }
)

# blocker -> blocked
$deps = @(
    @('map-p01', 'map-p02'), @('map-p02', 'map-p03'),
    @('map-p03', 'map-p04'), @('map-p03', 'map-p05'),
    @('map-p04', 'map-p06'), @('map-p05', 'map-p06'),
    @('map-p06', 'map-p07'), @('map-p01', 'map-p07'),
    @('map-p03', 'map-p08'), @('map-p01', 'map-p08'),
    @('map-p03', 'map-p09'),
    @('map-p04', 'map-p10'), @('map-p05', 'map-p10'), @('map-p06', 'map-p10'),
    @('map-p05', 'map-p11'), @('map-p06', 'map-p11'), @('map-p07', 'map-p11'),
    @('map-p08', 'map-p11'), @('map-p09', 'map-p11'), @('map-p10', 'map-p11'),
    @('map-p11', 'map-p12')
)

$existing = @()
$listed = bd list --json 2>$null | ConvertFrom-Json
if ($listed) { $existing = @($listed | ForEach-Object { $_.id }) }

foreach ($issue in $issues) {
    if ($existing -contains $issue.Id) {
        Write-Host "skip   $($issue.Id) (exists)"
        continue
    }
    bd create $issue.Title --id $issue.Id --type task --priority $issue.P `
        --description $issue.Desc --labels mission-apimpossible --silent | Out-Null
    Write-Host "create $($issue.Id)"
}

foreach ($dep in $deps) {
    bd dep $dep[0] --blocks $dep[1] 2>&1 | Out-Null
    Write-Host "dep    $($dep[0]) blocks $($dep[1])"
}

Write-Host ''
bd ready
