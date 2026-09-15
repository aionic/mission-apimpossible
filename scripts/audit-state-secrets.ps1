<#
.SYNOPSIS
    Gate G9: audits Terraform state for reusable authentication secrets.

.DESCRIPTION
    The state contract for this repository is narrow and worth stating exactly:

        No REUSABLE AUTHENTICATION SECRET may appear in Terraform state, saved
        plans, outputs, or logs.

    That is not the same as "no sensitive-looking string". A telemetry
    identifier is not a credential for the inference path, and pretending
    otherwise would either force a false claim or provoke contortions that make
    the sample worse. So this script classifies rather than merely greps:

      VIOLATION  - could authenticate someone to the model, the gateway, or a
                   host. Fails the gate.
      PERMITTED  - explicitly classified, with the reason recorded inline.
                   Enumerated here so it is a deliberate decision rather than
                   an oversight.

    Values are NEVER printed. Findings report the path, the length, and a
    truncated SHA-256 so two runs can be compared without revealing anything.

.EXAMPLE
    .\scripts\audit-state-secrets.ps1
    .\scripts\audit-state-secrets.ps1 -StatePath infra\terraform.tfstate.d\private\terraform.tfstate
#>
[CmdletBinding()]
param(
    [string]$StatePath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $StatePath) { $StatePath = Join-Path $repoRoot 'infra\terraform.tfstate' }
if (-not (Test-Path $StatePath)) { throw "State file not found: $StatePath" }

# Attribute names worth looking at. Deliberately broad - a false positive costs
# one line of classification, a false negative costs the security claim.
$suspectPattern = '(?i)(password|secret|_key$|^key$|primary|secondary|token|credential|connection_string|sas|certificate|thumbprint|private)'

# Findings that are acceptable, each with the reason it is acceptable. Anything
# not matched here fails the gate.
$permitted = @(
    @{ Pattern = 'application_insights.*connection_string|azurerm_application_insights\..*\.connection_string'
        Reason  = 'Telemetry ingestion identifier. Grants no access to the model, the gateway, or any host, and cannot authenticate a caller. Documented as a permitted non-credential.'
    }
    @{ Pattern = 'application_insights.*instrumentation_key|azurerm_application_insights\..*\.instrumentation_key'
        Reason  = 'Same as the connection string: a telemetry write identifier, not an inference credential.'
    }
    @{ Pattern = '\.tags\.'
        Reason  = 'Resource tags are non-secret metadata.'
    }
    @{ Pattern = 'certificate_source$|certificate_status$'
        Reason  = 'Enum describing WHERE a certificate comes from (for example "BuiltIn") and its status. Not a certificate. The sibling certificate and certificate_password fields are empty, which is the thing that actually matters.'
    }
    @{ Pattern = 'customer_managed_key|identity\.\d+\.principal_id|principal_id$'
        Reason  = 'An object ID is an identifier, not a secret.'
    }
)

$state = Get-Content $StatePath -Raw | ConvertFrom-Json

function Get-Fingerprint([string]$Value) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
    $sha.Dispose()
    return (-join ($h[0..3] | ForEach-Object { $_.ToString('x2') }))
}

$findings = [System.Collections.Generic.List[object]]::new()

function Walk($node, [string]$path) {
    if ($null -eq $node) { return }

    if ($node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $node.PSObject.Properties) {
            Walk $p.Value "$path.$($p.Name)"
        }
        return
    }
    if ($node -is [System.Object[]]) {
        for ($i = 0; $i -lt $node.Count; $i++) { Walk $node[$i] "$path.$i" }
        return
    }

    $leaf = ($path -split '\.')[-1]
    if ($leaf -notmatch $suspectPattern) { return }

    # An empty or boolean-ish value is not a secret. disable_local_auth=true is
    # a setting; "" is an absence.
    $text = [string]$node
    if ([string]::IsNullOrEmpty($text)) { return }
    if ($text -in @('True', 'False', 'true', 'false', '0')) { return }

    $findings.Add([pscustomobject]@{
            Path        = $path
            Length      = $text.Length
            Fingerprint = Get-Fingerprint $text
        })
}

foreach ($res in $state.resources) {
    $name = "$($res.type).$($res.name)"
    for ($i = 0; $i -lt $res.instances.Count; $i++) {
        Walk $res.instances[$i].attributes "$name[$i]"
    }
}
if ($state.outputs) { Walk $state.outputs 'output' }

Write-Host ""
Write-Host "G9 - Terraform state secret audit" -ForegroundColor Cyan
Write-Host "  state:     $StatePath"
Write-Host "  resources: $($state.resources.Count)"
Write-Host "==============================================================="

$violations = 0

if ($findings.Count -eq 0) {
    Write-Host "  No attribute matched the suspect-name pattern at all." -ForegroundColor Green
}

foreach ($f in $findings | Sort-Object Path) {
    $match = $permitted | Where-Object { $f.Path -match $_.Pattern } | Select-Object -First 1
    if ($match) {
        Write-Host "  PERMITTED  $($f.Path)" -ForegroundColor DarkGray
        Write-Host "             len=$($f.Length) fp=$($f.Fingerprint)" -ForegroundColor DarkGray
        Write-Host "             $($match.Reason)" -ForegroundColor DarkGray
    } else {
        $violations++
        Write-Host "  VIOLATION  $($f.Path)" -ForegroundColor Red
        Write-Host "             len=$($f.Length) fp=$($f.Fingerprint)" -ForegroundColor Red
    }
}

# Saved plans are state by another name, and are easy to forget.
Write-Host ""
Write-Host "Saved plans and backups" -ForegroundColor Cyan
$strays = Get-ChildItem -Path (Join-Path $repoRoot 'infra') -Recurse -ErrorAction SilentlyContinue |
Where-Object { $_.Name -match '\.tfplan$|tfplan\.binary$|\.tfstate\.backup$' }
if ($strays) {
    foreach ($s in $strays) {
        $tracked = (& git -C $repoRoot ls-files --error-unmatch $s.FullName 2>$null)
        if ($tracked) {
            Write-Host "  VIOLATION  tracked in git: $($s.Name)" -ForegroundColor Red
            $violations++
        } else {
            Write-Host "  ok (untracked) $($s.Name)" -ForegroundColor DarkGray
        }
    }
} else {
    Write-Host "  none present" -ForegroundColor DarkGray
}

Write-Host ""
if ($violations) {
    Write-Host "$violations violation(s). The state contract is broken." -ForegroundColor Red
    exit 1
}
Write-Host "State contains no reusable authentication secret." -ForegroundColor Green
