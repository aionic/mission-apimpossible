<#
.SYNOPSIS
    Gate G7: proves the request-validation ceilings fail CLOSED.

.DESCRIPTION
    Every case here is a request a well-behaved client would never send. The
    question is not whether the gateway understands them - it is whether the
    gateway refuses them safely, with a sanitized error and a correlation ID,
    rather than passing them to the model or collapsing into a 500.

    Uses HttpClient rather than Invoke-WebRequest because these cases need
    control the cmdlet does not give: exact byte counts, chunked framing with
    no Content-Length, raw invalid UTF-8, gzip content coding, and JSON that
    ConvertTo-Json would refuse to produce.

    A 500 is a FAILURE here even when the request is garbage. So is a 200.

.EXAMPLE
    . .\scripts\use-environment.ps1
    .\scripts\verify-request-validation.ps1
#>
[CmdletBinding()]
param(
    [string]$Endpoint = $env:MAP_ENDPOINT,
    [string]$Model = $env:MAP_MODEL,
    [string]$Scope = $env:MAP_SCOPE,

    # Must match map-max-request-bytes in the deployed gateway.
    [int]$MaxRequestBytes = 65536
)

$ErrorActionPreference = 'Stop'
if (-not $Endpoint) { throw "MAP_ENDPOINT is not set. Dot-source scripts/use-environment.ps1 first." }

$token = (az account get-access-token --scope $Scope --query accessToken --output tsv)
if (-not $token) { throw "Could not acquire a token for $Scope. Run: az login" }

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(120)

$utf8 = [System.Text.UTF8Encoding]::new($false)

function New-Body([hashtable]$Overrides = @{}) {
    $b = @{ model = $Model; input = 'Say ok.'; max_output_tokens = 16; store = $false }
    foreach ($k in $Overrides.Keys) { $b[$k] = $Overrides[$k] }
    return ($b | ConvertTo-Json -Compress -Depth 30)
}

$cases = [System.Collections.Generic.List[object]]::new()

function Add-Case {
    param(
        [string]$Name,
        [string]$Why,
        [byte[]]$Bytes,
        [string]$ContentType = 'application/json',
        [string]$ContentEncoding,
        [switch]$Chunked,
        [int[]]$Expect
    )
    $cases.Add([pscustomobject]@{
            Name = $Name; Why = $Why; Bytes = $Bytes; ContentType = $ContentType
            ContentEncoding = $ContentEncoding; Chunked = [bool]$Chunked; Expect = $Expect
        })
}

# --- positive control -------------------------------------------------------
# Without this, the whole suite passes against a gateway that rejects
# EVERYTHING, which is not the property under test. Every other case here
# expects a rejection, so at least one request must be shown to get through.
Add-Case -Name 'valid baseline request (control)' `
    -Why 'proves the suite is not passing merely because nothing works' `
    -Bytes $utf8.GetBytes((New-Body)) -Expect @(200)

# --- size boundary -----------------------------------------------------------
# Padding goes in `input`, so the aggregate-text limit may bite before the
# transport limit. Either is a correct rejection; passing is not.
$envelope = ([System.Text.Encoding]::UTF8.GetByteCount((New-Body @{ input = '' })))
$underPad = 'a' * ($MaxRequestBytes - $envelope - 64)
$overPad = 'a' * ($MaxRequestBytes - $envelope + 4096)

Add-Case -Name 'body just under the cap' `
    -Why 'a large but legal body must not be rejected by the size check' `
    -Bytes $utf8.GetBytes((New-Body @{ input = $underPad })) `
    -Expect @(200, 400, 413)

Add-Case -Name 'body over the cap' `
    -Why 'must be refused on bytes, not truncated and forwarded' `
    -Bytes $utf8.GetBytes((New-Body @{ input = $overPad })) `
    -Expect @(400, 413)

# --- framing -----------------------------------------------------------------
Add-Case -Name 'chunked, no Content-Length' `
    -Why 'a size cap that only reads Content-Length is trivially bypassed' `
    -Bytes $utf8.GetBytes((New-Body @{ input = $overPad })) -Chunked `
    -Expect @(400, 413)

Add-Case -Name 'gzip Content-Encoding' `
    -Why 'compressed oversize body: the cap must not be fooled by the wire size' `
    -Bytes (& {
        $raw = $utf8.GetBytes((New-Body @{ input = $overPad }))
        $ms = [System.IO.MemoryStream]::new()
        $gz = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Compress)
        $gz.Write($raw, 0, $raw.Length); $gz.Dispose()
        $ms.ToArray()
    }) -ContentEncoding 'gzip' `
    -Expect @(400, 413, 415)

# --- encoding ----------------------------------------------------------------
Add-Case -Name 'malformed UTF-8' `
    -Why 'invalid byte sequences must not reach the model or crash the parser' `
    -Bytes (& {
        $pre = $utf8.GetBytes('{"model":"' + $Model + '","input":"')
        $bad = [byte[]]@(0xC3, 0x28, 0xA0, 0xA1, 0xE2, 0x28, 0xA1)
        $post = $utf8.GetBytes('","max_output_tokens":16,"store":false}')
        $pre + $bad + $post
    }) -Expect @(400)

# --- JSON shape --------------------------------------------------------------
# ConvertTo-Json cannot emit a duplicate key, so this is hand-built. It matters:
# if the gateway reads the first `store` and the backend reads the last, the
# no-persistence guarantee is defeated by a parser disagreement.
Add-Case -Name 'duplicate store key (false then true)' `
    -Why 'parser disagreement must not smuggle store:true past the gateway' `
    -Bytes $utf8.GetBytes('{"model":"' + $Model + '","input":"Say ok.","max_output_tokens":16,"store":false,"store":true}') `
    -Expect @(400)

Add-Case -Name 'explicit store:true' `
    -Why 'the headline guarantee: server-side persistence is refused' `
    -Bytes $utf8.GetBytes((New-Body @{ store = $true })) -Expect @(400)

Add-Case -Name 'store as the string "false"' `
    -Why 'only a real boolean is acceptable; strings are ambiguous' `
    -Bytes $utf8.GetBytes('{"model":"' + $Model + '","input":"Say ok.","max_output_tokens":16,"store":"false"}') `
    -Expect @(400)

Add-Case -Name 'deeply nested JSON' `
    -Why 'depth must be bounded before the parser is' `
    -Bytes $utf8.GetBytes('{"model":"' + $Model + '","input":"Say ok.","store":false,"meta":' + ('[' * 200) + (']' * 200) + '}') `
    -Expect @(400)

Add-Case -Name 'unknown top-level property' `
    -Why 'the allowlist must reject unknown fields, not ignore them' `
    -Bytes $utf8.GetBytes((New-Body @{ previous_response_id = 'resp_abc123' })) -Expect @(400)

Add-Case -Name 'tools array' `
    -Why 'tool calling is outside this contract and must be refused' `
    -Bytes $utf8.GetBytes((New-Body @{ tools = @(@{ type = 'function'; name = 'rm' }) })) -Expect @(400)

Add-Case -Name 'truncated JSON' `
    -Why 'an unparseable body is a 400, never a 500' `
    -Bytes $utf8.GetBytes('{"model":"' + $Model + '","input":"Say ok.') -Expect @(400)

# --- content type ------------------------------------------------------------
Add-Case -Name 'text/plain content type' `
    -Why 'unspecified-content-type-action=prevent must hold' `
    -Bytes $utf8.GetBytes((New-Body)) -ContentType 'text/plain' -Expect @(400, 415)

# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "G7 - request validation ceilings" -ForegroundColor Cyan
Write-Host "  cap under test: $MaxRequestBytes bytes"
Write-Host "==============================================================="

$failures = 0

foreach ($c in $cases) {
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $Endpoint)
    $req.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
    $req.Content = [System.Net.Http.ByteArrayContent]::new($c.Bytes)
    $req.Content.Headers.ContentType =
    [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($c.ContentType)
    if ($c.ContentEncoding) { $req.Content.Headers.ContentEncoding.Add($c.ContentEncoding) }
    if ($c.Chunked) {
        $req.Headers.TransferEncodingChunked = $true
        $req.Content.Headers.ContentLength = $null
    }

    try {
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $status = [int]$resp.StatusCode
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        $corr = $null
        $v = $null
        if ($resp.Headers.TryGetValues('x-correlation-id', [ref]$v)) { $corr = $v | Select-Object -First 1 }
        $resp.Dispose()
    } catch {
        $status = 0; $text = $_.Exception.Message; $corr = $null
    }

    $ok = $c.Expect -contains $status
    $mark = if ($ok) { 'PASS' } else { 'FAIL' }
    $colour = if ($ok) { 'Green' } else { 'Red' }
    if (-not $ok) { $failures++ }

    '  {0}  {1,-34} HTTP {2,-4} ({3} bytes)' -f $mark, $c.Name, $status, $c.Bytes.Length |
    Write-Host -ForegroundColor $colour
    if (-not $ok) {
        Write-Host "        expected $($c.Expect -join ' or ') - $($c.Why)" -ForegroundColor Red
        Write-Host "        body: $($text.Substring(0, [Math]::Min(300, $text.Length)))" -ForegroundColor DarkGray
    }

    # A rejection nobody can trace is a rejection nobody can explain. This
    # applies to malformed input too, which is exactly when it is hardest.
    if ($status -ge 400 -and -not $corr) {
        Write-Host "        FAIL no x-correlation-id on a rejection" -ForegroundColor Red
        $failures++
    }

    # The error body must never carry internal detail outward.
    foreach ($leak in @('azure-api.net', 'cognitiveservices', 'openai.azure.com',
            'Microsoft.ApiManagement', 'StackTrace', 'Bearer ')) {
        if ($text -and $text -like "*$leak*") {
            Write-Host "        FAIL error body leaked '$leak'" -ForegroundColor Red
            $failures++
        }
    }
}

$client.Dispose()

Write-Host ""
if ($failures) {
    Write-Host "$failures check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "All request-validation ceilings hold." -ForegroundColor Green
