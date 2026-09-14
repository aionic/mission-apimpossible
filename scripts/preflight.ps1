<#
.SYNOPSIS
    Pre-provision checks. Runs before azd creates anything.

.DESCRIPTION
    Fails closed. Every check here exists because getting it wrong produces
    either a confusing mid-deployment failure or a silently weaker security
    posture.

    Reads no secrets and prints no tokens. It calls Azure only to read
    identity and quota metadata.

    Notably absent: any attempt to pick a model or region for you. Model GA
    status, regional availability, new-deployment eligibility, quota, and
    residency are separate checks (gate G11), and a helpful default here
    would invite deploying something stale.
#>
[CmdletBinding()]
param(
    [switch]$SkipAzureChecks
)

$ErrorActionPreference = 'Stop'
$problems = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Fail([string]$m) { $script:problems.Add($m); Write-Host "  FAIL  $m" -ForegroundColor Red }
function Warn([string]$m) { $script:warnings.Add($m); Write-Host "  WARN  $m" -ForegroundColor Yellow }
function Ok([string]$m)   { Write-Host "  ok    $m" -ForegroundColor Green }

function Test-Version {
    param([string]$Name, [string]$Actual, [string]$Minimum)
    try {
        $a = [version]($Actual -replace '[^0-9.].*$', '')
        $m = [version]$Minimum
        if ($a -ge $m) { Ok "$Name $Actual (>= $Minimum)"; return $true }
        Fail "$Name $Actual is below the required $Minimum"
        return $false
    } catch {
        Warn "$Name version '$Actual' could not be parsed; continuing"
        return $true
    }
}

Write-Host "`nMission APIMpossible preflight" -ForegroundColor Cyan
Write-Host "==============================`n"

# --- Toolchain -------------------------------------------------------------
Write-Host "Toolchain" -ForegroundColor Cyan

$tools = @(
    @{ Name = 'terraform'; Cmd = { (terraform version -json | ConvertFrom-Json).terraform_version }; Min = '1.16.0' }
    @{ Name = 'az';        Cmd = { (az version --output json | ConvertFrom-Json).'azure-cli' };      Min = '2.86.0' }
    @{ Name = 'azd';       Cmd = { (azd version) -replace '^azd version ([0-9.]+).*$', '$1' };       Min = '1.33.0' }
)

foreach ($tool in $tools) {
    $cmd = Get-Command $tool.Name -ErrorAction SilentlyContinue
    if (-not $cmd) { Fail "$($tool.Name) is not installed or not on PATH"; continue }
    try { Test-Version -Name $tool.Name -Actual (& $tool.Cmd) -Minimum $tool.Min | Out-Null }
    catch { Warn "could not determine $($tool.Name) version: $($_.Exception.Message)" }
}

# --- Policy and schema contracts ------------------------------------------
Write-Host "`nPolicy and schema contracts" -ForegroundColor Cyan
$validate = Join-Path $PSScriptRoot 'validate-policies.ps1'
if (Test-Path $validate) {
    # Write-Host output goes to stream 6; suppress the detail and surface only
    # the verdict. Run the script directly to see every check.
    & $validate 6>$null
    if ($LASTEXITCODE -eq 0) { Ok "policy invariants hold" }
    else { Fail "policy validation failed - run scripts/validate-policies.ps1 for detail" }
} else {
    Fail "scripts/validate-policies.ps1 is missing"
}

if ($SkipAzureChecks) {
    Write-Host "`nSkipping Azure checks (-SkipAzureChecks).`n" -ForegroundColor Yellow
} else {
    # --- Azure identity ----------------------------------------------------
    Write-Host "`nAzure identity" -ForegroundColor Cyan
    $account = $null
    try {
        $account = az account show --output json 2>$null | ConvertFrom-Json
    } catch { }

    if (-not $account) {
        Fail "not signed in to Azure CLI. Run: az login --tenant <tenant-id>"
    } else {
        Ok "signed in to subscription '$($account.name)'"
        Ok "tenant $($account.tenantId)"

        # The provisioning principal and the inference principal are different
        # roles. Conflating them is a common and consequential mistake: azd's
        # principal creates resources; the humans in inference_principal_ids
        # call the model.
        $configuredTenant = $env:TF_VAR_tenant_id
        if ($configuredTenant -and $configuredTenant -ne $account.tenantId) {
            Fail "TF_VAR_tenant_id ($configuredTenant) does not match the signed-in tenant ($($account.tenantId))"
        }

        if ($account.user.type -eq 'servicePrincipal') {
            Warn "signed in as a service principal. It can provision, but it must NOT be used as an inference test identity - that would not prove the human-identity path."
        }
    }

    # --- Resource providers ------------------------------------------------
    Write-Host "`nResource providers" -ForegroundColor Cyan
    $required = @(
        'Microsoft.ApiManagement',
        'Microsoft.CognitiveServices',
        'Microsoft.Insights',
        'Microsoft.OperationalInsights',
        'Microsoft.Network'
    )
    foreach ($rp in $required) {
        try {
            $state = az provider show --namespace $rp --query registrationState --output tsv 2>$null
            if ($state -eq 'Registered') { Ok "$rp registered" }
            else { Warn "$rp is '$state'. Terraform will attempt registration; this needs subscription-level permission." }
        } catch {
            Warn "could not query provider $rp"
        }
    }
}

# --- Deployment target -----------------------------------------------------
# These have no defaults on purpose. See gate G11.
Write-Host "`nDeployment target" -ForegroundColor Cyan

$targetVars = @(
    @{ Var = 'TF_VAR_location';         What = 'region' }
    @{ Var = 'TF_VAR_model_name';       What = 'model name' }
    @{ Var = 'TF_VAR_model_version';    What = 'model version' }
    @{ Var = 'TF_VAR_model_sku';        What = 'model SKU' }
    @{ Var = 'TF_VAR_api_audience';     What = 'token audience (gate G1)' }
)

$missing = @()
foreach ($t in $targetVars) {
    $value = [Environment]::GetEnvironmentVariable($t.Var)
    if ([string]::IsNullOrWhiteSpace($value)) { $missing += $t.What }
    else { Ok "$($t.What) = $value" }
}

if ($missing.Count -gt 0) {
    Warn "not set via environment: $($missing -join ', ')"
    Warn "supply them in a .tfvars file instead, or Terraform will prompt. There are no defaults by design."
}

# --- Result ----------------------------------------------------------------
Write-Host ""
if ($problems.Count -gt 0) {
    Write-Host "Preflight FAILED with $($problems.Count) problem(s):" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ""
    exit 1
}

if ($warnings.Count -gt 0) {
    Write-Host "Preflight passed with $($warnings.Count) warning(s)." -ForegroundColor Yellow
} else {
    Write-Host "Preflight passed." -ForegroundColor Green
}

Write-Host ""
Write-Host "Reminder: verify model availability, NEW-deployment eligibility, quota," -ForegroundColor Cyan
Write-Host "and data residency for your chosen region before provisioning." -ForegroundColor Cyan
Write-Host ""
exit 0
