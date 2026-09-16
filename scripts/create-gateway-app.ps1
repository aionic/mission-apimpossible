<#
.SYNOPSIS
    Creates the Entra application that authorises callers of the gateway.

.DESCRIPTION
    This is the control that decides WHO may use the gateway, and it has to
    exist before the first deployment.

    Why it is needed at all. The obvious configuration is to point the gateway
    at the Foundry audience, so a caller's token is already the right shape.
    That is a Microsoft FIRST-PARTY resource, and Entra issues tokens for those
    to any authenticated principal - issuance is not gated by RBAC on the
    model. In brokered mode the gateway calls the model with its own managed
    identity, so every member and guest of the tenant would get inference they
    hold no permission for, billed to the subscription. That was a real
    vulnerability in this repository, found by security review. See T19 in
    docs/threat-model.md.

    A dedicated application fixes it in two independent places:

      1. The enterprise application sets appRoleAssignmentRequired, so ENTRA
         refuses to issue a token to anyone not explicitly assigned.
      2. It exposes a specific scope, which the gateway policy then requires -
         a positive claim check rather than "some scope is present".

    The clients developers actually use are pre-authorised, so nobody sees a
    consent prompt. A custom API would otherwise require one; the first-party
    audience did not, which is part of why the original mistake looked fine.

    Idempotent. Safe to re-run.

.EXAMPLE
    .\scripts\create-gateway-app.ps1
    .\scripts\create-gateway-app.ps1 -AssignUser alice@contoso.com -AssignUser bob@contoso.com
#>
[CmdletBinding()]
param(
    [string]$DisplayName = 'Mission APIMpossible Gateway',

    [string]$ScopeName = 'Responses.Invoke',

    # Users or groups to authorise. The signed-in user is always included -
    # locking yourself out of your own deployment is a poor first experience.
    [string[]]$AssignUser = @(),
    [string[]]$AssignGroup = @(),

    # Clients permitted to request the scope without a consent prompt.
    # Defaults to Azure CLI (used by the local proxy and the Python client) and
    # VS Code (used by the extension).
    [string[]]$PreAuthorizeClient = @(
        '04b07795-8ddb-461a-bbee-02f9e1bf7b46',
        'aebc6443-996d-45c2-90f0-388ff96faa56'
    )
)

$ErrorActionPreference = 'Stop'

function Invoke-Graph {
    param([string]$Method, [string]$Uri, $Body)
    $args = @('rest', '--method', $Method, '--uri', $Uri, '-o', 'json')
    if ($Body) {
        $tmp = New-TemporaryFile
        ($Body | ConvertTo-Json -Depth 20 -Compress) | Out-File $tmp -Encoding utf8 -NoNewline
        $args += @('--headers', 'Content-Type=application/json', '--body', "@$tmp")
    }
    $result = & az @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Graph $Method $Uri failed: $result" }
    if ($Body) { Remove-Item $tmp -ErrorAction SilentlyContinue }
    if ($result) { return ($result | ConvertFrom-Json) }
}

Write-Host ""
Write-Host "Gateway application" -ForegroundColor Cyan
Write-Host "==============================================================="

# --- 1. Application -------------------------------------------------------
$appId = az ad app list --display-name $DisplayName --query "[0].appId" -o tsv 2>$null
if ($appId) {
    Write-Host "  Reusing existing application $appId" -ForegroundColor DarkGray
} else {
    $appId = (az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg --query appId -o tsv)
    if (-not $appId) { throw "Could not create the application. Do you have permission to register applications?" }
    Write-Host "  Created application $appId" -ForegroundColor Green
    Start-Sleep -Seconds 5
}

$objectId = az ad app show --id $appId --query id -o tsv

# --- 2. Exposed scope -----------------------------------------------------
$scopeId = az ad app show --id $appId --query "api.oauth2PermissionScopes[?value=='$ScopeName'].id | [0]" -o tsv 2>$null

if (-not $scopeId) {
    $scopeId = [guid]::NewGuid().ToString()
    Invoke-Graph -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$objectId" -Body @{
        identifierUris = @("api://$appId")
        api            = @{
            oauth2PermissionScopes = @(
                @{
                    id                      = $scopeId
                    value                   = $ScopeName
                    type                    = 'User'
                    isEnabled               = $true
                    adminConsentDisplayName = 'Invoke the governed model'
                    adminConsentDescription = 'Allows the signed-in developer to invoke the governed Responses endpoint.'
                    userConsentDisplayName  = 'Invoke the governed model'
                    userConsentDescription  = 'Allows this application to call the governed model as you.'
                }
            )
        }
    } | Out-Null
    Write-Host "  Exposed scope $ScopeName" -ForegroundColor Green
    Start-Sleep -Seconds 5
} else {
    Write-Host "  Scope $ScopeName already exposed" -ForegroundColor DarkGray
}

# --- 3. Pre-authorised clients --------------------------------------------
# Without this a developer meets a consent prompt on first use, because a
# custom API requires consent where a first-party audience does not.
Invoke-Graph -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$objectId" -Body @{
    api = @{
        preAuthorizedApplications = @(
            $PreAuthorizeClient | ForEach-Object {
                @{ appId = $_; delegatedPermissionIds = @($scopeId) }
            }
        )
    }
} | Out-Null
Write-Host "  Pre-authorised $($PreAuthorizeClient.Count) client application(s)" -ForegroundColor Green

# --- 4. Enterprise application, with assignment required ------------------
$spId = az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv 2>$null
if (-not $spId) {
    az ad sp create --id $appId -o none 2>$null
    Start-Sleep -Seconds 8
    $spId = az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv 2>$null
}
if (-not $spId) { throw "Could not create the enterprise application for $appId." }

# THE control. Without this the application is open to the whole tenant, which
# is the vulnerability this script exists to prevent.
az ad sp update --id $spId --set appRoleAssignmentRequired=true -o none 2>$null
Start-Sleep -Seconds 3
$required = az ad sp show --id $spId --query appRoleAssignmentRequired -o tsv

if ($required -ne 'true') {
    throw "appRoleAssignmentRequired is '$required', not true. Refusing to continue: without it any tenant member could use the gateway."
}
Write-Host "  User assignment required: enforced" -ForegroundColor Green

# --- 5. Assignments -------------------------------------------------------
$me = az ad signed-in-user show --query id -o tsv
$principals = [System.Collections.Generic.List[string]]::new()
$principals.Add($me)

foreach ($upn in $AssignUser) {
    $id = az ad user show --id $upn --query id -o tsv 2>$null
    if ($id) { $principals.Add($id) } else { Write-Host "  WARNING could not resolve user $upn" -ForegroundColor Yellow }
}
foreach ($g in $AssignGroup) {
    $id = az ad group show --group $g --query id -o tsv 2>$null
    if ($id) { $principals.Add($id) } else { Write-Host "  WARNING could not resolve group $g" -ForegroundColor Yellow }
}

$existing = @()
try {
    $existing = (Invoke-Graph -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo").value.principalId
} catch { }

foreach ($p in ($principals | Sort-Object -Unique)) {
    if ($existing -contains $p) { continue }
    try {
        Invoke-Graph -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo" -Body @{
            principalId = $p
            resourceId  = $spId
            appRoleId   = '00000000-0000-0000-0000-000000000000'
        } | Out-Null
        Write-Host "  Assigned $p" -ForegroundColor Green
    } catch {
        Write-Host "  WARNING could not assign $p : $_" -ForegroundColor Yellow
    }
}

# --- 6. What to do with it ------------------------------------------------
Write-Host ""
Write-Host "Add these to your profile tfvars:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  api_audience   = `"api://$appId`""
Write-Host "  required_scope = `"$ScopeName`""
Write-Host ""
Write-Host "Anyone not assigned to this application cannot obtain a token for it," -ForegroundColor DarkGray
Write-Host "so they cannot use the gateway - regardless of any Azure RBAC they hold." -ForegroundColor DarkGray
Write-Host "Manage access in Entra: Enterprise applications > $DisplayName > Users and groups." -ForegroundColor DarkGray
Write-Host ""
