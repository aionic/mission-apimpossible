<#
.SYNOPSIS
    Verifies that brokered identity mode actually eliminates the bypass.

.DESCRIPTION
    Brokered mode removes the direct-backend bypass by removing the human's
    permission. That guarantee holds ONLY if no OTHER role assignment grants
    the human Cognitive Services data actions.

    This is easy to get wrong and invisible unless you look: a role assigned
    at SUBSCRIPTION or MANAGEMENT GROUP scope is inherited by the Foundry
    account, and several Azure roles carry `Microsoft.CognitiveServices/*` as
    a dataAction - a wildcard that covers the Responses API. `Foundry User` is
    one of them.

    Removing the account-scope assignment while such a role is inherited
    produces a deployment that LOOKS correct - the gateway works, the account
    shows only the gateway identity - and still permits the bypass.

    Note that `Owner` is NOT one of these roles: it has no dataActions, so a
    PIM Owner elevation does not by itself grant inference.

.EXAMPLE
    .\scripts\verify-brokered-identity.ps1 -PrincipalId <entra-object-id>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PrincipalId,

    [string]$ResourceGroup = 'rg-map-map-public-example',
    [string]$AccountName   = 'oai-map-map-public-example'
)

$ErrorActionPreference = 'Stop'

$accountId = az cognitiveservices account show -n $AccountName -g $ResourceGroup --query id -o tsv
if (-not $accountId) { throw "Could not resolve the Foundry account $AccountName in $ResourceGroup." }

Write-Host ""
Write-Host "Brokered identity verification" -ForegroundColor Cyan
Write-Host "------------------------------"
Write-Host "  account   : $AccountName"
Write-Host "  principal : $PrincipalId"
Write-Host ""

# --- 1. Direct assignments at account scope -------------------------------
$direct = az role assignment list --assignee $PrincipalId --scope $accountId --output json |
          ConvertFrom-Json

if ($direct.Count -eq 0) {
    Write-Host "  [ok]   no role assigned directly at account scope" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] principal holds a role directly on the account:" -ForegroundColor Red
    $direct | ForEach-Object { Write-Host "           $($_.roleDefinitionName)" -ForegroundColor Red }
}

# --- 2. Inherited assignments - the part that is easy to miss -------------
$all = az role assignment list --assignee $PrincipalId --scope $accountId `
        --include-inherited --include-groups --output json | ConvertFrom-Json

Write-Host ""
Write-Host "  effective roles at this scope (including inherited):"
if ($all.Count -eq 0) {
    Write-Host "    (none)" -ForegroundColor Green
}

$offenders = @()
foreach ($assignment in $all) {
    $roleName = $assignment.roleDefinitionName

    $dataActions = @()
    try {
        $definition = az role definition list --name $roleName --output json | ConvertFrom-Json
        foreach ($perm in $definition[0].permissions) {
            if ($perm.dataActions) { $dataActions += $perm.dataActions }
        }
    } catch { }

    # Does this role confer Cognitive Services data-plane access?
    $grants = $dataActions | Where-Object {
        $_ -like 'Microsoft.CognitiveServices/*' -or $_ -eq '*'
    }

    if ($grants) {
        $offenders += [pscustomobject]@{ Role = $roleName; Scope = $assignment.scope; Actions = ($grants -join ', ') }
        Write-Host "    $roleName  ($($assignment.scope))" -ForegroundColor Red
        Write-Host "        grants dataActions: $($grants -join ', ')" -ForegroundColor Red
    } else {
        Write-Host "    $roleName  ($($assignment.scope))  - no CognitiveServices dataActions" -ForegroundColor DarkGray
    }
}

# --- Verdict --------------------------------------------------------------
Write-Host ""
if ($offenders.Count -eq 0 -and $direct.Count -eq 0) {
    Write-Host "  RESULT: brokered mode holds for this principal." -ForegroundColor Green
    Write-Host "          They cannot reach the model except through the gateway." -ForegroundColor Green
} else {
    Write-Host "  RESULT: BYPASS STILL POSSIBLE for this principal." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Brokered mode removed the account-scope grant, but an inherited" -ForegroundColor Yellow
    Write-Host "  role still confers Cognitive Services data-plane access. The" -ForegroundColor Yellow
    Write-Host "  deployment will look correct and the bypass will still work." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Resolve by removing or re-scoping the inherited assignment(s)" -ForegroundColor Yellow
    Write-Host "  above, or accept and document the residual risk." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
exit 0
