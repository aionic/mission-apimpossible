<#
.SYNOPSIS
    Re-scopes a subscription-wide Foundry User assignment to individual
    resource groups, excluding the Mission APIMpossible one.

.DESCRIPTION
    WHY THIS EXISTS

    Brokered identity mode removes the human's inference RBAC on the Foundry
    account, which is what eliminates the direct-backend bypass. That
    guarantee holds only if no OTHER assignment grants the same data actions.

    A `Foundry User` assignment at SUBSCRIPTION scope grants
    `Microsoft.CognitiveServices/*` as a dataAction, which the Foundry account
    inherits - so the bypass stays open while the account itself shows only
    the gateway identity. Everything looks correct and is not.

    This script replaces one broad assignment with narrower ones: the
    principal keeps data-plane access to every resource group that currently
    has a Cognitive Services account, EXCEPT the Mission APIMpossible one.

    BEHAVIOUR CHANGE, deliberate: a new AI account created in a NEW resource
    group will no longer inherit access. Grant it explicitly. That is better
    hygiene than a subscription-wide data-plane wildcard, but it is a change.

    Run with -WhatIf first. Nothing is removed until the replacements exist.

.EXAMPLE
    .\scripts\rescope-foundry-user.ps1 -PrincipalId <oid> -WhatIf
    .\scripts\rescope-foundry-user.ps1 -PrincipalId <oid>
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$PrincipalId,

    [string]$RoleName = 'Foundry User',

    [string]$ExcludeResourceGroup = 'rg-map-map-public-example',

    [string]$SubscriptionId = '00000000-0000-0000-0000-000000000000'
)

$ErrorActionPreference = 'Stop'
$subScope = "/subscriptions/$SubscriptionId"

Write-Host ""
Write-Host "Re-scope '$RoleName' for $PrincipalId" -ForegroundColor Cyan
Write-Host "---------------------------------------------------------------"

# --- 1. Find the subscription-scope assignment ----------------------------
$existing = az role assignment list --assignee $PrincipalId --scope $subScope --output json |
            ConvertFrom-Json |
            Where-Object { $_.roleDefinitionName -eq $RoleName -and $_.scope -eq $subScope }

if (-not $existing) {
    Write-Host "  No subscription-scope '$RoleName' assignment found. Nothing to do." -ForegroundColor Green
    exit 0
}

Write-Host "  Found assignment: $($existing.name)"
Write-Host ""
Write-Host "  RESTORE COMMAND - save this before proceeding:" -ForegroundColor Yellow
Write-Host "    az role assignment create --assignee $PrincipalId ``" -ForegroundColor Yellow
Write-Host "      --role '$RoleName' --scope $subScope" -ForegroundColor Yellow
Write-Host ""

# --- 2. Work out the target resource groups -------------------------------
$groups = az cognitiveservices account list --query "[].resourceGroup" -o tsv |
          Sort-Object -Unique |
          Where-Object { $_ -and $_ -ne $ExcludeResourceGroup }

if (-not $groups) {
    Write-Host "  No other resource groups hold Cognitive Services accounts." -ForegroundColor Yellow
    Write-Host "  Re-scoping would leave no access at all; aborting." -ForegroundColor Yellow
    exit 1
}

Write-Host "  Will grant '$RoleName' at these resource groups:"
$groups | ForEach-Object { Write-Host "    + $_" -ForegroundColor Green }
Write-Host "  Excluded (this is the point): $ExcludeResourceGroup" -ForegroundColor Cyan
Write-Host ""

# --- 3. Create the narrower assignments FIRST -----------------------------
# Order matters: never remove access before the replacement exists.
$created = 0
foreach ($group in $groups) {
    $scope = "$subScope/resourceGroups/$group"

    $already = az role assignment list --assignee $PrincipalId --scope $scope --output json |
               ConvertFrom-Json |
               Where-Object { $_.roleDefinitionName -eq $RoleName -and $_.scope -eq $scope }

    if ($already) {
        Write-Host "  = $group (already assigned)" -ForegroundColor DarkGray
        continue
    }

    if ($PSCmdlet.ShouldProcess($scope, "Assign '$RoleName'")) {
        az role assignment create --assignee $PrincipalId --role $RoleName --scope $scope --output none
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  + $group" -ForegroundColor Green
            $created++
        } else {
            Write-Host "  ! $group FAILED - stopping before removal" -ForegroundColor Red
            exit 1
        }
    }
}

# --- 4. Only now remove the broad one -------------------------------------
if ($PSCmdlet.ShouldProcess($subScope, "Remove subscription-scope '$RoleName'")) {
    Write-Host ""
    Write-Host "  Removing the subscription-scope assignment..." -ForegroundColor Cyan
    az role assignment delete --ids $existing.id --output none
    if ($LASTEXITCODE -ne 0) { throw "Failed to remove the subscription-scope assignment." }
    Write-Host "  Removed." -ForegroundColor Green
}

Write-Host ""
Write-Host "  Azure RBAC removal can take several minutes to reach the data" -ForegroundColor Yellow
Write-Host "  plane. Wait before concluding the bypass is closed." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Then verify:" -ForegroundColor Cyan
Write-Host "    .\scripts\verify-brokered-identity.ps1 -PrincipalId $PrincipalId"
Write-Host ""
