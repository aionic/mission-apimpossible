<#
.SYNOPSIS
    Prepares the private-pattern Windows jumpbox.

.DESCRIPTION
    Runs once via the Azure CustomScript extension. Idempotent: re-running is
    safe and is how the extension behaves on VM restart.

    Installs the tooling a developer needs to exercise the private path from
    inside the VNet: VS Code, Azure CLI, Python, uv, and git.

    Security properties this script must preserve:
      * no credentials are embedded, logged, or written to disk;
      * installs come from vendor endpoints over HTTPS via winget, whose
        manifests are publisher-signed;
      * the local bootstrap account is disabled once Entra sign-in is healthy,
        so no shared password remains usable.

    Gate G4 caveat: the bootstrap-account disablement below is the mechanism
    that makes the write-only password acceptable. It has not been proven
    against a real VM - see docs/platform-validation.md.
#>
[CmdletBinding()]
param(
    [string]$BootstrapAccount = 'mapbootstrap'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$logDir = 'C:\ProgramData\MissionAPIMpossible'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'bootstrap.log'

function Write-Log([string]$Message) {
    $line = "[{0:yyyy-MM-ddTHH:mm:ssZ}] {1}" -f (Get-Date).ToUniversalTime(), $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

Write-Log 'Starting jumpbox bootstrap.'

# --- winget ----------------------------------------------------------------
# Present on current Windows 11 images. If missing, fail loudly rather than
# silently downloading installers from arbitrary URLs.
$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    Write-Log 'ERROR: winget is unavailable. Not falling back to ad-hoc downloads.'
    throw 'winget is required for verifiable, publisher-signed installs.'
}

$packages = @(
    @{ Id = 'Microsoft.VisualStudioCode'; Name = 'Visual Studio Code' }
    @{ Id = 'Microsoft.AzureCLI';         Name = 'Azure CLI' }
    @{ Id = 'Python.Python.3.12';         Name = 'Python 3.12' }
    @{ Id = 'astral-sh.uv';               Name = 'uv' }
    @{ Id = 'Git.Git';                    Name = 'Git' }
)

foreach ($pkg in $packages) {
    Write-Log "Installing $($pkg.Name) ($($pkg.Id))..."
    try {
        # --scope machine so tooling is available to every Entra user who
        # signs in, not just the bootstrap profile.
        & winget install --id $pkg.Id --exact --silent `
            --accept-package-agreements --accept-source-agreements `
            --scope machine --disable-interactivity 2>&1 | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Write-Log "  installed $($pkg.Name)"
        } elseif ($LASTEXITCODE -eq -1978335189) {
            Write-Log "  $($pkg.Name) already present"
        } else {
            Write-Log "  WARNING: $($pkg.Name) returned exit code $LASTEXITCODE"
        }
    } catch {
        Write-Log "  WARNING: $($pkg.Name) failed: $($_.Exception.Message)"
    }
}

# --- Entra sign-in readiness ----------------------------------------------
# The bootstrap account is only disabled once the extension reports healthy.
# Disabling it before Entra login works would lock everyone out of the VM.
Write-Log 'Checking AADLoginForWindows health...'

$aadHealthy = $false
try {
    $svc = Get-Service -Name 'AADBrokerPlugin*' -ErrorAction SilentlyContinue
    $extPath = 'C:\Packages\Plugins\Microsoft.Azure.ActiveDirectory.AADLoginForWindows'
    $joinState = (& dsregcmd /status 2>&1 | Out-String)

    if ((Test-Path $extPath) -and ($joinState -match 'AzureAdJoined\s*:\s*YES')) {
        $aadHealthy = $true
    }
    Write-Log "  extension present: $(Test-Path $extPath); AzureAdJoined matched: $($joinState -match 'AzureAdJoined\s*:\s*YES')"
} catch {
    Write-Log "  WARNING: health check failed: $($_.Exception.Message)"
}

if ($aadHealthy) {
    try {
        $account = Get-LocalUser -Name $BootstrapAccount -ErrorAction SilentlyContinue
        if ($account -and $account.Enabled) {
            Disable-LocalUser -Name $BootstrapAccount
            Write-Log "Disabled bootstrap account '$BootstrapAccount'. Entra sign-in is the only interactive path."
        } else {
            Write-Log "Bootstrap account '$BootstrapAccount' already disabled or absent."
        }
    } catch {
        Write-Log "WARNING: could not disable bootstrap account: $($_.Exception.Message)"
    }
} else {
    Write-Log 'Entra sign-in not confirmed healthy; leaving the bootstrap account enabled to avoid lockout.'
    Write-Log 'ACTION REQUIRED: confirm Entra sign-in, then disable the account manually or re-run this script.'
}

# --- Guidance for the tester ----------------------------------------------
$readme = @"
Mission APIMpossible - private test jumpbox
===========================================

This VM sits inside the private VNet. It exists to prove two things:

  1. VS Code and the Python CLI can reach the APIM gateway privately using
     YOUR Microsoft Entra identity.

  2. The SAME identity CANNOT reach Azure OpenAI directly, even though it
     holds Cognitive Services OpenAI User. That call is blocked by NSG rules
     on the Foundry private endpoint subnet.

Test (2) explicitly - a private endpoint alone would NOT stop it, so the
denial is the thing worth verifying:

    curl -i https://<foundry-account>.openai.azure.com/openai/v1/responses

Expected: connection failure or timeout. If it succeeds, the anti-bypass
control has regressed. Report it.

Getting started:
    az login --tenant <tenant-id>
    cd C:\repo\mission-apimpossible
    uv run python examples\python\respond.py "Review this function."

Note: anything you open in VS Code here persists on this VM's disk. Treat the
jumpbox as holding the same data classification as your workstation.
"@

Set-Content -Path (Join-Path $env:PUBLIC 'Desktop\README-jumpbox.txt') -Value $readme -Encoding UTF8

Write-Log 'Bootstrap complete.'
