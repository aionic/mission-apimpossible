<#
.SYNOPSIS
    Gate G5: proves what the token-governance policies actually enforce.

.DESCRIPTION
    The gateway applies TWO independent limits to the same caller, and they are
    easy to confuse because both surface as HTTP 429:

      1. rate-limit-by-key   - a coarse request-rate guard (calls per second).
      2. llm-token-limit     - a token-per-minute ceiling plus a daily quota.

    They fail for different reasons, and a sample that cannot tell them apart
    cannot honestly describe either. They are distinguishable at runtime:
    llm-token-limit sets x-ratelimit-remaining-tokens on its rejection;
    rate-limit-by-key does not.

    Two load shapes, because they prove different things:

      -Mode Sequential   one request at a time. Establishes that the accounting
                         headers are present and plausible on the happy path.
                         This mode is EXPECTED NOT TO THROTTLE - see below.

      -Mode Burst        N requests in flight at once. This is the only shape
                         that reliably trips a limit.

    Measured finding (see docs/platform-validation.md): sequential load does not
    exhaust a per-minute token bucket when each request takes ~15s. Roughly four
    requests fit in the window, ~1,200 tokens each, against a 20,000 ceiling -
    and tokens age out of the sliding window as fast as they are consumed. Over
    24 consecutive requests `remaining` oscillated between 17,430 and 18,939 and
    never trended downward. That is correct behaviour, not a broken limit, and
    it is why this script offers a burst mode at all.

.EXAMPLE
    . .\scripts\use-environment.ps1
    .\scripts\verify-token-governance.ps1 -Mode Burst -Requests 12
#>
[CmdletBinding()]
param(
    [ValidateSet('Sequential', 'Burst')]
    [string]$Mode = 'Burst',

    [int]$Requests = 12,

    # Tokens per request. The default is deliberately large: a 20,000 TPM
    # ceiling cannot be reached by trivial requests. A 14-request burst of
    # 16-token replies consumed 18 tokens each and left `remaining` at 19,982
    # - correct, and useless as a test of the limit.
    [int]$MaxOutputTokens = 4096,

    [string]$Endpoint = $env:MAP_ENDPOINT,
    [string]$Model = $env:MAP_MODEL,
    [string]$Scope = $env:MAP_SCOPE
)

$ErrorActionPreference = 'Stop'

if (-not $Endpoint) { throw "MAP_ENDPOINT is not set. Dot-source scripts/use-environment.ps1 first." }
if (-not $Scope) { throw "MAP_SCOPE is not set. Dot-source scripts/use-environment.ps1 first." }

Write-Host ""
Write-Host "G5 - token governance ($Mode, $Requests requests)" -ForegroundColor Cyan
Write-Host "==============================================================="

# One token for the whole run. Refreshing mid-run would be a different test:
# the counter key is tid:oid, so a new token for the same human must land on
# the SAME counter. That is asserted separately, below.
$token = (az account get-access-token --scope $Scope --query accessToken --output tsv)
if (-not $token) { throw "Could not acquire a token for $Scope. Run: az login" }

$body = @{
    model             = $Model
    input             = 'Write a detailed explanation of how TLS 1.3 performs its handshake, covering every message in order.'
    max_output_tokens = $MaxOutputTokens
    store             = $false
} | ConvertTo-Json -Compress

# Runs in a background job, so it must be self-contained - no closure over the
# parent scope.
$probe = {
    param($Index, $Endpoint, $Token, $Body)

    $headers = @{
        'Authorization'          = "Bearer $Token"
        'Content-Type'           = 'application/json'
        'x-ms-client-request-id' = [guid]::NewGuid().ToString()
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest -Uri $Endpoint -Method Post -Headers $headers `
            -Body $Body -SkipHttpErrorCheck -TimeoutSec 180
        $sw.Stop()

        # Header lookup that tolerates absence, which is the whole point here.
        $get = {
            param($n)
            if ($r.Headers.ContainsKey($n)) { return ($r.Headers[$n] | Select-Object -First 1) }
            return $null
        }

        [pscustomobject]@{
            Index      = $Index
            Status     = [int]$r.StatusCode
            Seconds    = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            Remaining  = & $get 'x-ratelimit-remaining-tokens'
            Consumed   = & $get 'x-ratelimit-consumed-tokens'
            RetryAfter = & $get 'Retry-After'
            Correlation = & $get 'x-correlation-id'
            Error      = $null
        }
    } catch {
        $sw.Stop()
        [pscustomobject]@{
            Index = $Index; Status = 0; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            Remaining = $null; Consumed = $null; RetryAfter = $null; Correlation = $null
            Error = $_.Exception.Message
        }
    }
}

$results = @()

if ($Mode -eq 'Sequential') {
    for ($i = 1; $i -le $Requests; $i++) {
        $r = & $probe $i $Endpoint $token $body
        $results += $r
        '  [{0,2}] {1,6}s  HTTP {2}  remaining={3,-8} consumed={4,-6} retry-after={5}' -f `
            $r.Index, $r.Seconds, $r.Status, $r.Remaining, $r.Consumed, $r.RetryAfter | Write-Host
    }
} else {
    # True concurrency, via async HttpClient rather than background jobs.
    #
    # Start-Job was the obvious approach and it is wrong for this test.
    # Spinning up a PowerShell runspace costs a few hundred milliseconds each,
    # so ten "concurrent" jobs actually arrive spread over several seconds -
    # which is slow enough to slip under a per-second rate limit and prove
    # nothing. These SendAsync calls are all in flight within milliseconds.
    Write-Host "  launching $Requests truly concurrent requests..." -ForegroundColor DarkGray

    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(180)

    $pending = [System.Collections.Generic.List[object]]::new()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    for ($i = 1; $i -le $Requests; $i++) {
        $req = [System.Net.Http.HttpRequestMessage]::new(
            [System.Net.Http.HttpMethod]::Post, $Endpoint)
        $req.Headers.Authorization =
            [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
        $req.Headers.Add('x-ms-client-request-id', [guid]::NewGuid().ToString())
        $req.Content = [System.Net.Http.StringContent]::new(
            $body, [System.Text.Encoding]::UTF8, 'application/json')

        $pending.Add([pscustomobject]@{ Index = $i; Task = $client.SendAsync($req) })
    }

    Write-Host ("  all $Requests dispatched in {0:N0} ms" -f $sw.Elapsed.TotalMilliseconds) -ForegroundColor DarkGray

    foreach ($p in $pending) {
        $elapsed = $null
        try {
            $resp = $p.Task.GetAwaiter().GetResult()
            $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)

            $get = {
                param($n)
                $v = $null
                if ($resp.Headers.TryGetValues($n, [ref]$v)) { return ($v | Select-Object -First 1) }
                if ($resp.Content.Headers.TryGetValues($n, [ref]$v)) { return ($v | Select-Object -First 1) }
                return $null
            }

            $results += [pscustomobject]@{
                Index       = $p.Index
                Status      = [int]$resp.StatusCode
                Seconds     = $elapsed
                Remaining   = & $get 'x-ratelimit-remaining-tokens'
                Consumed    = & $get 'x-ratelimit-consumed-tokens'
                RetryAfter  = & $get 'Retry-After'
                Correlation = & $get 'x-correlation-id'
                Error       = $null
            }
            $resp.Dispose()
        } catch {
            $results += [pscustomobject]@{
                Index = $p.Index; Status = 0
                Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                Remaining = $null; Consumed = $null; RetryAfter = $null; Correlation = $null
                Error = $_.Exception.Message
            }
        }
    }

    $client.Dispose()
    $results = $results | Sort-Object Index

    foreach ($r in $results) {
        '  [{0,2}] {1,6}s  HTTP {2}  remaining={3,-8} consumed={4,-6} retry-after={5}' -f `
            $r.Index, $r.Seconds, $r.Status, $r.Remaining, $r.Consumed, $r.RetryAfter | Write-Host
    }
}

# ---------------------------------------------------------------------------
# Classify, rather than just counting 429s.
# ---------------------------------------------------------------------------
$ok = @($results | Where-Object Status -eq 200)
$throttled = @($results | Where-Object Status -eq 429)
$other = @($results | Where-Object { $_.Status -ne 200 -and $_.Status -ne 429 })

# llm-token-limit reports remaining tokens even when it rejects.
# rate-limit-by-key has no concept of tokens and reports none.
$byTokens = @($throttled | Where-Object { $_.Remaining })
$byRate = @($throttled | Where-Object { -not $_.Remaining })

Write-Host ""
Write-Host "Result" -ForegroundColor Cyan
Write-Host "  200 OK                       $($ok.Count)"
Write-Host "  429 from llm-token-limit     $($byTokens.Count)   (TPM / daily quota)"
Write-Host "  429 from rate-limit-by-key   $($byRate.Count)   (request-rate guard)"
if ($other.Count) {
    Write-Host "  other                        $($other.Count)" -ForegroundColor Yellow
    $other | ForEach-Object { Write-Host "      [$($_.Index)] HTTP $($_.Status) $($_.Error)" -ForegroundColor Yellow }
}

$pass = $true

if ($ok.Count -gt 0) {
    $missing = @($ok | Where-Object { -not $_.Remaining -or -not $_.Consumed })
    if ($missing.Count) {
        Write-Host "  FAIL accounting headers absent on $($missing.Count) successful responses" -ForegroundColor Red
        $pass = $false
    } else {
        Write-Host "  PASS accounting headers present on every successful response" -ForegroundColor Green
    }
}

if ($throttled.Count -gt 0) {
    $noRetry = @($throttled | Where-Object { -not $_.RetryAfter })
    if ($noRetry.Count) {
        Write-Host "  WARN $($noRetry.Count) throttled responses carried no Retry-After" -ForegroundColor Yellow
    } else {
        Write-Host "  PASS every throttled response carried Retry-After" -ForegroundColor Green
    }
} elseif ($Mode -eq 'Burst') {
    Write-Host "  INCONCLUSIVE no limit was reached. Raise -Requests and retry." -ForegroundColor Yellow
    $pass = $false
} else {
    Write-Host "  EXPECTED sequential load does not exhaust a sliding window." -ForegroundColor DarkGray
}

# Every response, throttled or not, must still be correlatable. A rejection the
# operator cannot trace is a rejection the operator cannot explain.
$uncorrelated = @($results | Where-Object { $_.Status -ne 0 -and -not $_.Correlation })
if ($uncorrelated.Count) {
    Write-Host "  FAIL $($uncorrelated.Count) responses had no x-correlation-id" -ForegroundColor Red
    $pass = $false
} else {
    Write-Host "  PASS every response carried x-correlation-id" -ForegroundColor Green
}

Write-Host ""
if (-not $pass) { exit 1 }
