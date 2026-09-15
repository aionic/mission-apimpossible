<#
.SYNOPSIS
    Finds the request size the gateway actually tolerates.

.DESCRIPTION
    Gate G7 recorded a documentation contradiction and never resolved it: the
    validate-content reference permits max-size up to 4 MB, the gateway runtime
    limits table lists 100 KiB for bodies that policy processes, and APIM v2
    has a separate 2 MiB buffered-payload limit. Those are three different
    numbers for three different things, and no amount of reading settles which
    one bites first.

    The original answer was to pick 64 KiB - comfortably under all of them -
    and move on. Measurement made that untenable: a single GitHub Copilot
    agent-mode turn sent 133 KB of input plus 88 function-tool definitions. An
    IDE carries accumulated context and its whole tool catalogue on every
    request, so a single-prompt-sized budget is not a budget at all.

    This probes upward until something breaks, and reports WHAT broke. The
    distinction matters:

      400 invalid_request   the gateway's own size check - our configuration
      413                   a payload limit above our check
      500 / 502             APIM failing to process a body it accepted, which
                            is the failure mode the runtime-limits table warns
                            about and the one worth knowing the boundary of

.EXAMPLE
    . .\scripts\use-environment.ps1
    .\scripts\probe-size-ceiling.ps1
#>
[CmdletBinding()]
param(
    [string]$Endpoint = $env:MAP_ENDPOINT,
    [string]$Model = $env:MAP_MODEL,
    [string]$Scope = $env:MAP_SCOPE,

    # KiB. Spans the three documented ceilings so whichever bites is visible.
    [int[]]$Sizes = @(64, 100, 128, 192, 256, 384, 512, 768, 1024)
)

$ErrorActionPreference = 'Stop'
if (-not $Endpoint) { throw "MAP_ENDPOINT is not set. Dot-source scripts/use-environment.ps1 first." }

$token = (az account get-access-token --scope $Scope --query accessToken --output tsv)
if (-not $token) { throw "Could not acquire a token. Run: az login" }

Write-Host ""
Write-Host "G7 - actual request size ceiling" -ForegroundColor Cyan
Write-Host "==============================================================="
Write-Host "  documented, and mutually inconsistent:" -ForegroundColor DarkGray
Write-Host "    validate-content max-size      up to 4 MB" -ForegroundColor DarkGray
Write-Host "    gateway runtime limits table   100 KiB processed bodies" -ForegroundColor DarkGray
Write-Host "    v2 buffered payload            2 MiB" -ForegroundColor DarkGray
Write-Host ""

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(180)

$lastGood = 0
$firstBad = $null

foreach ($kib in $Sizes) {
    # Pad inside a content part, so the body is shaped like a real request
    # rather than one enormous string the parser might treat differently.
    $target = $kib * 1024
    $envelope = 400
    $pad = 'a' * [Math]::Max(1, $target - $envelope)

    $body = @{
        model             = $Model
        store             = $false
        max_output_tokens = 16
        input             = @(
            @{
                type    = 'message'
                role    = 'user'
                content = @(@{ type = 'input_text'; text = "Reply with OK. Context: $pad" })
            }
        )
    } | ConvertTo-Json -Depth 20 -Compress

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)

    $req = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Post, $Endpoint)
    $req.Headers.Authorization =
        [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
    $req.Content = [System.Net.Http.ByteArrayContent]::new($bytes)
    $req.Content.Headers.ContentType =
        [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/json')

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $status = [int]$resp.StatusCode
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $resp.Dispose()
    } catch {
        $status = 0
        $text = $_.Exception.Message
    }
    $sw.Stop()

    $code = ''
    try { $code = ($text | ConvertFrom-Json).error.code } catch { }

    $verdict = switch ($status) {
        200 { 'ok'; break }
        400 { "rejected by our own size check ($code)"; break }
        413 { 'payload too large'; break }
        default { "UNEXPECTED - $code" }
    }

    $colour = if ($status -eq 200) { 'Green' } elseif ($status -in 400, 413) { 'Yellow' } else { 'Red' }
    '  {0,5} KiB  {1,9:N0} B  {2,5:N1}s  HTTP {3,-4} {4}' -f `
        $kib, $bytes.Length, $sw.Elapsed.TotalSeconds, $status, $verdict | Write-Host -ForegroundColor $colour

    if ($status -eq 200) {
        $lastGood = $kib
    } elseif (-not $firstBad) {
        $firstBad = [pscustomobject]@{ Kib = $kib; Status = $status; Code = $code }
    }
}

$client.Dispose()

Write-Host ""
Write-Host "Result" -ForegroundColor Cyan
Write-Host "  largest accepted   $lastGood KiB"
if ($firstBad) {
    Write-Host "  first rejected     $($firstBad.Kib) KiB - HTTP $($firstBad.Status) $($firstBad.Code)"
    if ($firstBad.Status -ge 500) {
        Write-Host "  WARNING a 5xx means APIM accepted a body it could not process." -ForegroundColor Red
        Write-Host "          Set max_request_bytes BELOW this, so the gateway rejects" -ForegroundColor Red
        Write-Host "          it cleanly instead of failing after the fact." -ForegroundColor Red
    }
} else {
    Write-Host "  nothing was rejected - raise -Sizes to find the real ceiling." -ForegroundColor Yellow
}
Write-Host ""
