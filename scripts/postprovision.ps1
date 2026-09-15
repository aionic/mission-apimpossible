<#
.SYNOPSIS
    Prints the client configuration after a successful provision.

.DESCRIPTION
    Reads azd environment values and shows what to set for the Python CLI and
    the VS Code extension, plus the verification steps that actually matter.

    Prints no secrets - there are none to print. The architecture has no
    runtime keys.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-AzdValue([string]$Name) {
    try {
        $values = azd env get-values --output json 2>$null | ConvertFrom-Json
        return $values.$Name
    } catch { return $null }
}

$endpoint   = Get-AzdValue 'MAP_RESPONSES_ENDPOINT'
$model      = Get-AzdValue 'MAP_MODEL_DEPLOYMENT'
$tenant     = Get-AzdValue 'MAP_TENANT_ID'
$audience   = Get-AzdValue 'MAP_API_AUDIENCE'
$profile    = Get-AzdValue 'DEPLOYMENT_PROFILE'
$foundry    = Get-AzdValue 'FOUNDRY_DIRECT_ENDPOINT'
$jumpbox    = Get-AzdValue 'JUMPBOX_NAME'
$bastion    = Get-AzdValue 'BASTION_NAME'
$rg         = Get-AzdValue 'RESOURCE_GROUP_NAME'

Write-Host ""
Write-Host "Mission APIMpossible - deployed" -ForegroundColor Green
Write-Host "===============================" -ForegroundColor Green
Write-Host ""
Write-Host "Profile:  $profile"
Write-Host "Endpoint: $endpoint"
Write-Host "Model:    $model"
Write-Host ""

Write-Host "Client configuration" -ForegroundColor Cyan
Write-Host "--------------------"
Write-Host "  `$env:MAP_ENDPOINT = `"$endpoint`""
Write-Host "  `$env:MAP_MODEL    = `"$model`""
Write-Host "  `$env:MAP_TENANT_ID = `"$tenant`""
Write-Host "  `$env:MAP_SCOPE    = `"$audience/.default`""
Write-Host ""
Write-Host "  There is no API key to set. There is no key." -ForegroundColor DarkGray
Write-Host ""

Write-Host "Try it" -ForegroundColor Cyan
Write-Host "------"
Write-Host "  az login --tenant $tenant"
Write-Host "  uv run python examples/python/respond.py `"Review this function for concurrency bugs.`""
Write-Host ""

Write-Host "Verify the security posture" -ForegroundColor Cyan
Write-Host "---------------------------"

$directResponses = "$($foundry -replace '/$', '')/openai/v1/responses"

if ($profile -eq 'private') {
    Write-Host "  The test that matters: from the jumpbox, try to reach the model directly." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    curl -i $directResponses"
    Write-Host ""
    Write-Host "  EXPECTED: connection failure or timeout - even though your identity holds"
    Write-Host "  Cognitive Services OpenAI User. A private endpoint alone would NOT block"
    Write-Host "  this; the NSG rules on the Foundry PE subnet are what do."
    Write-Host ""
    Write-Host "  If that call SUCCEEDS, the anti-bypass control has regressed. Report it." -ForegroundColor Red
    Write-Host ""

    if ($jumpbox) {
        Write-Host "  Connect to the jumpbox:"
        Write-Host "    az network bastion rdp --name $bastion --resource-group $rg ``"
        Write-Host "      --target-resource-id <vm-resource-id> --enable-mfa"
        Write-Host ""
        Write-Host "  NOTE: gate G4 is unresolved. Native-client Entra RDP prompts for a" -ForegroundColor Yellow
        Write-Host "  password, and portal Entra RDP is in preview. See" -ForegroundColor Yellow
        Write-Host "  docs/deployment.md." -ForegroundColor Yellow
        Write-Host ""
    }
} else {
    Write-Host "  This is the PUBLIC pattern. A developer holding inference RBAC can reach" -ForegroundColor Yellow
    Write-Host "  Foundry directly and bypass every gateway control:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    $directResponses"
    Write-Host ""
    Write-Host "  That is expected here and is an accepted residual risk of the public"
    Write-Host "  sample. Deploy the private pattern to prevent it."
    Write-Host ""
}

Write-Host "Tear down with: azd down --purge" -ForegroundColor DarkGray
Write-Host ""
