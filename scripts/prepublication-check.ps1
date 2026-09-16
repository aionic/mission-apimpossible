<#
.SYNOPSIS
    Pre-publication review: secrets, live identifiers, and stale claims.

.DESCRIPTION
    Run before making the repository public, and in CI to stop regressions.

    Three classes of problem, and they are genuinely different:

      SECRET      a credential. Blocks publication outright.
      IDENTIFIER  a real subscription, tenant, resource or principal from
                  whatever environment this was developed in. Not a
                  credential, but it leaks internal detail and hardcodes the
                  sample to one environment so nobody else can run it.
      STALE       a documented claim that the code no longer supports. The
                  most corrosive of the three, because a reader has no way to
                  tell it is wrong - and this repository has already shipped
                  a README claiming it had never been deployed, three days
                  after it was.

    Live identifiers are supplied rather than hardcoded here, for the obvious
    reason that hardcoding them would be the thing this script detects.

.EXAMPLE
    .\scripts\prepublication-check.ps1
    .\scripts\prepublication-check.ps1 -LiveIdentifiers @('05322c41-...','example')
#>
[CmdletBinding()]
param(
    # Extra environment-specific strings to hunt for. Defaults to values
    # discovered from the current az session and Terraform outputs.
    [string[]]$LiveIdentifiers = @()
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot

$problems = 0

function Fail([string]$class, [string]$detail) {
    Write-Host "  $class  $detail" -ForegroundColor Red
    $script:problems++
}

Write-Host ""
Write-Host "Pre-publication review" -ForegroundColor Cyan
Write-Host "==============================================================="

# --- 1. files that must never be tracked ------------------------------------
Write-Host ""
Write-Host "Tracked files" -ForegroundColor Cyan
$forbidden = git ls-files | Where-Object {
    $_ -match '\.tfstate|\.tfplan$|tfplan\.binary|\.env$|\.pem$|\.pfx$|\.p12$|proxy\.key|id_rsa|\.vsix$|^\.azure/|\.tfvars$'
}
if ($forbidden) { $forbidden | ForEach-Object { Fail 'SECRET    ' "tracked: $_" } }
else { Write-Host "  ok  no state, plans, keys, certs, vsix or tfvars tracked" -ForegroundColor Green }

# --- 2. credential-shaped content -------------------------------------------
Write-Host ""
Write-Host "Credential patterns" -ForegroundColor Cyan
$patterns = @{
    'JWT'                  = 'eyJ[A-Za-z0-9_-]{10,}\.eyJ'
    'PEM private key'      = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'connection string'    = 'AccountKey=[A-Za-z0-9+/=]{20,}'
    'APIM subscription key' = 'Ocp-Apim-Subscription-Key:\s*[A-Za-z0-9]{20,}'
    'az storage key'       = 'DefaultEndpointsProtocol=.*AccountKey='
}
foreach ($name in $patterns.Keys) {
    # Exclude this script, which necessarily contains the patterns themselves.
    $hits = git grep -n -I -E -- $patterns[$name] 2>$null |
    Where-Object { $_ -notmatch 'prepublication-check\.ps1' }
    if ($hits) { $hits | Select-Object -First 5 | ForEach-Object { Fail 'SECRET    ' "$name : $_" } }
}
if ($problems -eq 0) { Write-Host "  ok  no credential-shaped content" -ForegroundColor Green }

# --- 3. live environment identifiers ----------------------------------------
Write-Host ""
Write-Host "Environment identifiers" -ForegroundColor Cyan

$discovered = [System.Collections.Generic.List[string]]::new()
foreach ($v in $LiveIdentifiers) { if ($v) { $discovered.Add($v) } }

# Discover rather than hardcode.
$sub = (az account show --query id -o tsv 2>$null)
$ten = (az account show --query tenantId -o tsv 2>$null)
$oid = (az ad signed-in-user show --query id -o tsv 2>$null)
foreach ($v in @($sub, $ten, $oid)) { if ($v) { $discovered.Add($v.Trim()) } }

$infra = Join-Path $repoRoot 'infra'
$raw = & terraform "-chdir=$infra" output -json 2>$null
if ($LASTEXITCODE -eq 0 -and $raw) {
    $out = $raw | ConvertFrom-Json
    foreach ($key in 'RESOURCE_GROUP_NAME', 'FOUNDRY_ACCOUNT_NAME') {
        if ($out.PSObject.Properties.Name -contains $key) {
            $value = $out.$key.value
            if ($value) {
                $discovered.Add($value)
                # The random suffix is the part that identifies the deployment.
                if ($value -match '([a-z0-9]{6})$') { $discovered.Add($Matches[1]) }
            }
        }
    }
}

$unique = $discovered | Sort-Object -Unique | Where-Object { $_.Length -ge 6 }
if (-not $unique) {
    Write-Host "  skipped  not signed in and no Terraform outputs; nothing to compare against" -ForegroundColor Yellow
} else {
    $found = $false
    foreach ($id in $unique) {
        $hits = git grep -n -I -F -- $id 2>$null |
        Where-Object { $_ -notmatch 'prepublication-check\.ps1' }
        if ($hits) {
            $found = $true
            $hits | Select-Object -First 5 | ForEach-Object { Fail 'IDENTIFIER' $_ }
        }
    }
    if (-not $found) {
        Write-Host "  ok  none of $($unique.Count) live identifier(s) appear in tracked files" -ForegroundColor Green
    }
}

# --- 4. stale documentation claims ------------------------------------------
Write-Host ""
Write-Host "Stale claims" -ForegroundColor Cyan

# Each: a pattern that must NOT appear, and why it is now false.
$staleClaims = @(
    @{ Pattern = 'has not yet been deployed|not yet been deployed to Azure'
        Why     = 'deployed and proven live'
    }
    @{ Pattern = 'designed, not yet implemented|designed, not yet built'
        Why     = 'the proxy is implemented and proven'
    }
    @{ Pattern = 'forward the SAME token unchanged'
        Why     = 'brokered is the default; passthrough is the alternative'
    }
    @{ Pattern = '\| `tools`, `functions`, `tool_choice` \| External interaction'
        Why     = 'client-side function tools are accepted'
    }
    @{ Pattern = 'Rejected: tools, functions'
        Why     = 'client-side function tools are accepted; only HOSTED tools are rejected'
    }
    @{ Pattern = '\| `max_output_tokens` \| 4096 \|'
        Why     = 'raised to 32768; 4096 truncated real coding work'
    }
    @{ Pattern = '\| Message history \| 400 entries \|'
        Why     = 'raised to 1000'
    }
)

$staleFound = $false
foreach ($claim in $staleClaims) {
    $hits = git grep -n -I -E -- $claim.Pattern -- '*.md' 2>$null |
    Where-Object { $_ -notmatch 'prepublication-check\.ps1' }
    if ($hits) {
        $staleFound = $true
        $hits | Select-Object -First 4 | ForEach-Object { Fail 'STALE     ' "$_   [$($claim.Why)]" }
    }
}
if (-not $staleFound) { Write-Host "  ok  no known stale claims" -ForegroundColor Green }

# --- 5. internal links ------------------------------------------------------
Write-Host ""
Write-Host "Documentation links" -ForegroundColor Cyan
$broken = 0
foreach ($doc in (Get-ChildItem -Recurse -Include '*.md' -File | Where-Object { $_.FullName -notmatch 'node_modules|\.beads' })) {
    foreach ($m in [regex]::Matches((Get-Content $doc.FullName -Raw), '\]\((?!https?:)([^)#]+)\)')) {
        $target = Join-Path $doc.Directory $m.Groups[1].Value
        if (-not (Test-Path $target)) {
            Fail 'LINK      ' "$($doc.Name) -> $($m.Groups[1].Value)"
            $broken++
        }
    }
}
if ($broken -eq 0) { Write-Host "  ok  every internal link resolves" -ForegroundColor Green }

Pop-Location

Write-Host ""
if ($problems) {
    Write-Host "$problems problem(s). Not ready to publish." -ForegroundColor Red
    exit 1
}
Write-Host "Ready to publish." -ForegroundColor Green
