<#
.SYNOPSIS
    Downloads the latest UniFiAutoTaskAlertBridge scripts from GitHub.
.DESCRIPTION
    Run this script from any folder to pull the latest versions of all scripts
    from the main branch. Existing files are overwritten.

    Usage:
        .\Download-Scripts.ps1

    To download to a specific folder:
        .\Download-Scripts.ps1 -Destination 'C:\Scripts\UniFi'
#>

param(
    [string]$Destination = $PSScriptRoot
)

$BaseUrl = 'https://raw.githubusercontent.com/radverth/unifiautotaskalertbridge/main'

$Scripts = @(
    'Invoke-UniFiAlerts.ps1'
    'Invoke-UniFiDattoMonitor-Manual.ps1'
    'Invoke-UniFiDattoMonitor-DattoAPI.ps1'
)

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

if (-not (Test-Path $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}

foreach ($script in $Scripts) {
    $url     = "$BaseUrl/$script"
    $outFile = Join-Path $Destination $script
    try {
        Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing
        Write-Host "OK  $script" -ForegroundColor Green
    }
    catch {
        Write-Host "FAIL $script — $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host "Scripts saved to: $Destination" -ForegroundColor Cyan
