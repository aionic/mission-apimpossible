<#
.SYNOPSIS
    Offline validation for APIM policy XML and JSON contract schemas.

.DESCRIPTION
    Runs no Azure calls and needs no credentials, so it is safe in CI on
    untrusted pull requests.

    Checks:
      1. every policy XML file is well-formed;
      2. every policy references only fragments that exist;
      3. the security invariants that must never regress;
      4. every JSON spec parses.

    The invariant checks are the important part. They exist because the whole
    architecture rests on a handful of properties that would be easy to break
    accidentally during a refactor, and whose failure would be silent.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure([string]$Message) {
    $script:failures.Add($Message)
    Write-Host "  FAIL  $Message" -ForegroundColor Red
}

function Write-Ok([string]$Message) {
    Write-Host "  ok    $Message" -ForegroundColor Green
}

# --- 1. XML well-formedness ------------------------------------------------
Write-Host "`nPolicy XML well-formedness" -ForegroundColor Cyan
$policyFiles = Get-ChildItem (Join-Path $repoRoot 'policies') -Recurse -Filter *.xml | Sort-Object Name
if ($policyFiles.Count -eq 0) { Add-Failure "no policy files found" }

foreach ($file in $policyFiles) {
    $doc = New-Object System.Xml.XmlDocument
    try {
        $doc.Load($file.FullName)
        Write-Ok $file.Name
    } catch {
        Add-Failure "$($file.Name): $($_.Exception.InnerException.Message)"
    }
}

# --- 2. Fragment references resolve ---------------------------------------
Write-Host "`nFragment references" -ForegroundColor Cyan
$fragmentDir = Join-Path $repoRoot 'policies\fragments'
$availableFragments = Get-ChildItem $fragmentDir -Filter *.xml |
    ForEach-Object { "map-$($_.BaseName)" }

foreach ($file in $policyFiles) {
    $content = Get-Content $file.FullName -Raw
    $matches = [regex]::Matches($content, 'fragment-id="([^"]+)"')
    foreach ($m in $matches) {
        $id = $m.Groups[1].Value
        if ($availableFragments -contains $id) {
            Write-Ok "$($file.Name) -> $id"
        } else {
            Add-Failure "$($file.Name) references unknown fragment '$id'"
        }
    }
}

# --- 3. Security invariants ------------------------------------------------
# Each of these protects a property the architecture depends on. A refactor
# that breaks one of them would otherwise fail silently and only surface in a
# security review, or not at all.
#
# Comments are stripped before scanning: these files legitimately DISCUSS the
# forbidden policies in prose ("there is no authentication-managed-identity
# policy here"), and matching that prose would be a false positive.
Write-Host "`nSecurity invariants" -ForegroundColor Cyan

function Get-PolicyBody([string]$Path) {
    $raw = Get-Content $Path -Raw
    return [regex]::Replace($raw, '(?s)<!--.*?-->', '')
}

$allPolicyText = ($policyFiles | ForEach-Object { Get-PolicyBody $_.FullName }) -join "`n"

$invariants = @(
    @{ Name = 'no managed-identity authentication to the backend'
       Pattern = 'authentication-managed-identity'
       Why = 'would replace the developer token with a service identity, destroying end-to-end human identity' }
    @{ Name = 'no basic authentication'
       Pattern = 'authentication-basic'
       Why = 'this architecture uses no shared credentials' }
    @{ Name = 'no certificate authentication to the backend'
       Pattern = 'authentication-certificate'
       Why = 'would introduce a backend credential distinct from the caller' }
    @{ Name = 'Authorization header is never overwritten'
       Pattern = '<set-header\s+name="Authorization"'
       Why = 'the forwarded token must be byte-identical to the one the developer acquired' }
    @{ Name = 'no api-key header injection'
       Pattern = '<set-header\s+name="api-key"[^>]*>\s*<value>'
       Why = 'local key auth is disabled on the backend and no key may be introduced' }
    @{ Name = 'no subscription key requirement'
       Pattern = 'Ocp-Apim-Subscription-Key[^>]*>\s*<value>'
       Why = 'runtime access is Entra-only; no subscription keys are issued' }
    @{ Name = 'no semantic caching'
       Pattern = 'semantic-cache'
       Why = 'coding prompts carry proprietary source; cross-user cache hits are a data-isolation problem' }
    @{ Name = 'no response body logging'
       Pattern = '<log-to-eventhub'
       Why = 'model output must never enter a telemetry path' }
)

foreach ($inv in $invariants) {
    if ($allPolicyText -match $inv.Pattern) {
        Add-Failure "invariant broken: $($inv.Name) -- $($inv.Why)"
    } else {
        Write-Ok $inv.Name
    }
}

# Positive invariants: things that MUST be present.
$required = @(
    @{ Name = 'SSE forwarding is unbuffered'
       Pattern = 'buffer-response="false"'
       File = 'responses.xml'
       Why = 'the default is true, which buffers the stream and breaks server-sent events' }
    @{ Name = 'token validation is present'
       Pattern = 'validate-azure-ad-token'
       File = 'authentication.xml'
       Why = 'without it the gateway would forward unvalidated tokens' }
    @{ Name = 'validated token is published to a variable'
       Pattern = 'output-token-variable-name'
       File = 'authentication.xml'
       Why = 'claims must come from the validated token, never from parsing the raw header' }
    @{ Name = 'store=false is injected'
       Pattern = 'body\["store"\] = false'
       File = 'request-validation.xml'
       Why = 'statelessness must not depend on client behavior' }
    @{ Name = 'per-user token limit is keyed on validated claims'
       Pattern = 'quota-key'
       File = 'token-governance.xml'
       Why = 'keying on anything caller-supplied would let a user escape their own counter' }
)

foreach ($req in $required) {
    $file = $policyFiles | Where-Object { $_.Name -eq $req.File } | Select-Object -First 1
    if (-not $file) {
        Add-Failure "expected policy file '$($req.File)' not found"
        continue
    }
    $text = Get-PolicyBody $file.FullName
    if ($text -match $req.Pattern) {
        Write-Ok $req.Name
    } else {
        Add-Failure "missing requirement: $($req.Name) in $($req.File) -- $($req.Why)"
    }
}

# --- 4. JSON specs ---------------------------------------------------------
Write-Host "`nJSON specifications" -ForegroundColor Cyan
foreach ($file in (Get-ChildItem (Join-Path $repoRoot 'specs') -Filter *.json -ErrorAction SilentlyContinue)) {
    try {
        Get-Content $file.FullName -Raw | ConvertFrom-Json | Out-Null
        Write-Ok $file.Name
    } catch {
        Add-Failure "$($file.Name): $($_.Exception.Message)"
    }
}

# --- Result ----------------------------------------------------------------
Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "All policy and specification checks passed." -ForegroundColor Green
exit 0
