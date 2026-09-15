<#
.SYNOPSIS
    Removes resources Azure creates automatically, which otherwise block
    resource-group deletion.

.DESCRIPTION
    Terraform destroys what Terraform created. Azure also creates things on
    your behalf, and those are invisible to the state file.

    Application Insights automatically provisions a Smart Detector alert rule
    named "Failure Anomalies - <app-insights-name>". No Terraform resource
    declares it and no provider flag prevents it. `terraform destroy` therefore
    removes everything it owns, then fails on the final step with:

        Error: deleting Resource Group "...": the Resource Group still
        contains Resources.

    The message does not say which resource, so the natural next step is to go
    hunting in the portal. This script is the answer, and it runs before
    destroy rather than after a confusing failure.

    Safety: this only ever deletes auto-generated rules whose name begins with
    "Failure Anomalies - ", and only inside the named resource group. Anything
    else is left alone and reported.

.EXAMPLE
    .\scripts\predown.ps1 -ResourceGroup rg-map-map-public-abc123
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = $env:RESOURCE_GROUP_NAME
)

$ErrorActionPreference = 'Stop'

if (-not $ResourceGroup) {
    Write-Host "No resource group supplied; nothing to clean up." -ForegroundColor DarkGray
    return
}

if ((az group exists -n $ResourceGroup) -ne 'true') {
    Write-Host "Resource group $ResourceGroup does not exist; nothing to clean up." -ForegroundColor DarkGray
    return
}

Write-Host "Removing auto-created alert rules from $ResourceGroup..." -ForegroundColor Cyan

$rules = az resource list -g $ResourceGroup `
    --resource-type 'microsoft.alertsmanagement/smartDetectorAlertRules' `
    --query "[].{id:id, name:name}" -o json | ConvertFrom-Json

if (-not $rules) {
    Write-Host "  none found" -ForegroundColor DarkGray
    return
}

foreach ($r in $rules) {
    if ($r.name -notlike 'Failure Anomalies - *') {
        Write-Host "  SKIP $($r.name) - not an auto-generated rule, leaving it alone." -ForegroundColor Yellow
        continue
    }
    Write-Host "  deleting $($r.name)"
    az resource delete --ids $r.id -o none
}

Write-Host "Done. 'terraform destroy' can now remove the resource group." -ForegroundColor Green
