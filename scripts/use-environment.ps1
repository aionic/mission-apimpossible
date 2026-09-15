<#
.SYNOPSIS
    Loads the deployed environment into the current shell for testing.

.DESCRIPTION
    Reads Terraform outputs and sets the MAP_* variables the Python client and
    curl examples expect. Dot-source it so the variables persist:

        . .\scripts\use-environment.ps1 -ProfileName private

    Sets no secrets, because there are none. Authentication is your own Entra
    identity via `az login`.

    Each profile owns a separate Terraform workspace, so that deploying or
    destroying one cannot touch the other. `terraform output` only ever reports
    the CURRENTLY selected workspace, so this script selects the right one
    first - reading outputs without doing that silently returns the other
    environment's endpoint, which is a confusing way to test the wrong gateway.
#>
[CmdletBinding()]
param(
    [ValidateSet('public', 'private')]
    [string]$ProfileName = 'public'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$infra = Join-Path $repoRoot 'infra'

if (-not (Test-Path (Join-Path $infra '.terraform'))) {
    throw "Terraform is not initialized. Run: terraform -chdir=infra init"
}

# public lives in the implicit 'default' workspace; private in its own.
$workspace = if ($ProfileName -eq 'public') { 'default' } else { $ProfileName }
$current = (& terraform "-chdir=$infra" workspace show 2>$null)

if ($current -and $current.Trim() -ne $workspace) {
    Write-Host "Switching Terraform workspace $current -> $workspace" -ForegroundColor Cyan
    & terraform "-chdir=$infra" workspace select $workspace 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not select workspace '$workspace'. Has the $ProfileName profile been deployed?"
    }
}

Write-Host "Reading Terraform outputs..." -ForegroundColor Cyan
$raw = & terraform "-chdir=$infra" output -json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $raw) {
    throw "No Terraform outputs found in workspace '$workspace'. Has the $ProfileName profile been deployed?"
}

$out = $raw | ConvertFrom-Json

function Get-Out([string]$Name) {
    if ($out.PSObject.Properties.Name -contains $Name) { return $out.$Name.value }
    return $null
}

$env:MAP_ENDPOINT  = Get-Out 'MAP_RESPONSES_ENDPOINT'
$env:MAP_MODEL     = Get-Out 'MAP_MODEL_DEPLOYMENT'
$env:MAP_TENANT_ID = Get-Out 'MAP_TENANT_ID'
$env:MAP_SCOPE     = "$(Get-Out 'MAP_API_AUDIENCE')/.default"

$profileDeployed = Get-Out 'DEPLOYMENT_PROFILE'
$foundry         = Get-Out 'FOUNDRY_DIRECT_ENDPOINT'
$appInsights     = Get-Out 'APP_INSIGHTS_NAME'
$resourceGroup   = Get-Out 'RESOURCE_GROUP_NAME'

Write-Host ""
Write-Host "Mission APIMpossible - $profileDeployed pattern" -ForegroundColor Green
Write-Host "------------------------------------------------"
Write-Host "  MAP_ENDPOINT   $env:MAP_ENDPOINT"
Write-Host "  MAP_MODEL      $env:MAP_MODEL"
Write-Host "  MAP_TENANT_ID  $env:MAP_TENANT_ID"
Write-Host "  MAP_SCOPE      $env:MAP_SCOPE"
Write-Host ""
Write-Host "  There is no API key to set. There is no key." -ForegroundColor DarkGray
Write-Host ""

# Confirm the caller is signed in as a human, not a service principal - using
# a service principal here would not demonstrate the human-identity path at
# all, and the gateway would reject it as an app-only token.
$account = $null
try { $account = az account show --output json 2>$null | ConvertFrom-Json } catch { }

if (-not $account) {
    Write-Host "  NOT SIGNED IN. Run: az login --tenant $env:MAP_TENANT_ID" -ForegroundColor Yellow
} elseif ($account.tenantId -ne $env:MAP_TENANT_ID) {
    Write-Host "  Signed into tenant $($account.tenantId), but the gateway only" -ForegroundColor Yellow
    Write-Host "  accepts $env:MAP_TENANT_ID. Run:" -ForegroundColor Yellow
    Write-Host "      az login --tenant $env:MAP_TENANT_ID" -ForegroundColor Yellow
} elseif ($account.user.type -eq 'servicePrincipal') {
    Write-Host "  Signed in as a SERVICE PRINCIPAL. The gateway rejects app-only" -ForegroundColor Yellow
    Write-Host "  tokens with 403 not_delegated_identity - by design." -ForegroundColor Yellow
} else {
    Write-Host "  Signed in as $($account.user.name)" -ForegroundColor Green
}

Write-Host ""
Write-Host "Try it:" -ForegroundColor Cyan
Write-Host "  uv run python examples/python/respond.py `"Review this for races.`""
Write-Host "  uv run python examples/python/respond.py --stream `"Count to five.`""
Write-Host ""

if ($profileDeployed -eq 'public') {
    Write-Host "Note: this is the PUBLIC pattern. A direct call to" -ForegroundColor DarkGray
    Write-Host "  ${foundry}openai/v1/responses" -ForegroundColor DarkGray
    Write-Host "will SUCCEED and bypass every gateway control. That is the" -ForegroundColor DarkGray
    Write-Host "documented residual risk the private pattern exists to remove." -ForegroundColor DarkGray
    Write-Host ""
}

Write-Host "Telemetry: $appInsights (resource group $resourceGroup)" -ForegroundColor DarkGray
Write-Host ""
