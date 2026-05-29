<#
.SYNOPSIS
    UniFi network health monitor for Datto RMM.
.DESCRIPTION
    Reads the UnifiSiteKeys site variable, queries the UniFi Cloud API for each
    host/network, evaluates alert conditions, and exits with code 1 if any issues
    are found so Datto RMM raises an alert.

    Site variables required (set at site level in Datto RMM):
        UnifiSiteKeys  — one of:
            HostID
            HostId1|NetworkId1,HostId2|NetworkId2
        UnifiApiKey    — UniFi Cloud API key from account.ui.com

    Exit codes:
        0 — all sites healthy
        1 — one or more alert conditions detected
        2 — configuration error (missing variables)
#>

Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'

#region CONFIGURATION

$UnifiApiBase = 'https://api.ui.com/v1'

# API key — set directly here for now.
# To switch to a Datto RMM global variable later, comment out the line below
# and uncomment the global variable line beneath it.
$UnifiApiKey  = 'YOUR_API_KEY_HERE'
# $UnifiApiKey = $env:CS_UnifiApiKey   # <- uncomment when using Datto global variable

# Site variable — always read from the Datto RMM site variable
$SiteKeysRaw  = $env:CS_UnifiSiteKeys

# Alert thresholds — mirror your main script values
$TxRetryWarningPct   = 50.0
$TxRetryCriticalPct  = 55.0
$WanUptimeWarningPct = 99.0

#endregion

#region VALIDATION

if (-not $UnifiApiKey -or $UnifiApiKey -eq 'YOUR_API_KEY_HERE') {
    Write-Host 'CONFIGURATION ERROR: UnifiApiKey is not set. Add your API key to the script or configure the Datto global variable.'
    exit 2
}

if (-not $SiteKeysRaw) {
    Write-Host 'CONFIGURATION ERROR: Site variable UnifiSiteKeys is not set.'
    exit 2
}

#endregion

#region HELPERS

function Parse-SiteKeys {
    param([string]$Raw)
    $entries = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($part in $Raw.Split(',')) {
        $part = $part.Trim()
        if (-not $part) { continue }
        if ($part.Contains('|')) {
            $split = $part.Split('|', 2)
            $entries.Add(@{ HostId = $split[0].Trim(); NetworkId = $split[1].Trim() })
        }
        else {
            $entries.Add(@{ HostId = $part; NetworkId = $null })
        }
    }
    return $entries
}

function Invoke-UniFiRequest {
    param(
        [string]$Endpoint,
        [hashtable]$QueryParams = @{}
    )

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    $uri = "$UnifiApiBase$Endpoint"
    if ($QueryParams.Count -gt 0) {
        $qs = ($QueryParams.GetEnumerator() | ForEach-Object {
            $k = [System.Uri]::EscapeDataString($_.Key) -replace '%5B','[' -replace '%5D',']'
            "$k=$([System.Uri]::EscapeDataString($_.Value.ToString()))"
        }) -join '&'
        $uri = "${uri}?${qs}"
    }

    $wc = [System.Net.WebClient]::new()
    $wc.Headers.Add('Accept', 'application/json')
    $wc.Headers.Add('X-API-Key', $UnifiApiKey)

    $uriObj = New-Object System.Uri($uri, $true)
    $raw     = $wc.DownloadString($uriObj)
    return $raw | ConvertFrom-Json
}

function Get-HostName {
    param([string]$HostId)
    try {
        $resp = Invoke-UniFiRequest -Endpoint "/hosts/$HostId"
        $obj  = if ($resp.data) { $resp.data } else { $resp }
        if ($obj -and $obj.hostName) { return $obj.hostName }
    }
    catch { }
    return $HostId
}

function Get-Devices {
    param([string]$HostId)

    $all       = [System.Collections.Generic.List[object]]::new()
    $nextToken = $null

    do {
        $encodedId = [System.Uri]::EscapeDataString($HostId)
        $qs = "hostIds[]=$encodedId&pageSize=100"
        if ($nextToken) { $qs += "&nextToken=$([System.Uri]::EscapeDataString($nextToken))" }

        $uri    = "$UnifiApiBase/devices?$qs"
        $uriObj = New-Object System.Uri($uri, $true)

        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $wc = [System.Net.WebClient]::new()
        $wc.Headers.Add('Accept', 'application/json')
        $wc.Headers.Add('X-API-Key', $UnifiApiKey)

        try {
            $raw      = $wc.DownloadString($uriObj)
            $response = $raw | ConvertFrom-Json
        }
        catch { break }

        $wrappers = if ($response.data) { $response.data } elseif ($response -is [array]) { $response } else { @() }
        foreach ($wrapper in $wrappers) {
            if ($wrapper.hostId -and $wrapper.hostId -ne $HostId) { continue }
            $devs = if ($wrapper.devices) { $wrapper.devices } elseif ($wrapper.mac) { @($wrapper) } else { @() }
            foreach ($d in $devs) { $all.Add($d) }
        }

        $nextToken = if ($response.nextToken) { $response.nextToken } else { $null }
    } while ($nextToken)

    return $all
}

function Get-SiteStats {
    param([string]$HostId)
    try {
        $resp  = Invoke-UniFiRequest -Endpoint '/sites' -QueryParams @{ pageSize = 200 }
        $sites = if ($resp.data) { $resp.data } elseif ($resp -is [array]) { $resp } else { @() }
        return $sites | Where-Object { $_.hostId -eq $HostId } | Select-Object -First 1
    }
    catch { return $null }
}

#endregion

#region ALERT EVALUATION

$alerts   = [System.Collections.Generic.List[string]]::new()
$entries  = Parse-SiteKeys -Raw $SiteKeysRaw

foreach ($entry in $entries) {
    $hostId    = $entry.HostId
    $networkId = $entry.NetworkId

    # Resolve display name
    $hostName = Get-HostName -HostId $hostId
    $label    = if ($networkId) { "$hostName (net: $networkId)" } else { $hostName }

    # Get devices
    $devices = @(Get-Devices -HostId $hostId)

    # Get site statistics (WAN uptime, TX retry, etc.)
    $site   = Get-SiteStats -HostId $hostId
    $stats  = if ($site -and $site.statistics) { $site.statistics } else { $null }
    $pct    = if ($stats -and $stats.percentages) { $stats.percentages } else { $null }
    $counts = if ($stats -and $stats.counts) { $stats.counts } else { $null }

    # --- Offline devices ---
    $offlineDevices  = @($devices | Where-Object { $_.status -eq 'offline' })
    $offlineCount    = if ($counts -and $null -ne $counts.offlineDevice) { [int]$counts.offlineDevice } else { $offlineDevices.Count }

    if ($offlineCount -gt 1) {
        $nameList = if ($offlineDevices.Count -gt 0) {
            ($offlineDevices | ForEach-Object { if ($_.name) { $_.name } else { $_.model } }) -join ', '
        } else { 'multiple devices' }
        $alerts.Add("[$label] OUTAGE: $offlineCount devices offline — $nameList")
    }
    elseif ($offlineCount -eq 1) {
        $dev  = $offlineDevices | Select-Object -First 1
        $name = if ($dev -and $dev.name) { $dev.name } elseif ($dev -and $dev.model) { $dev.model } else { 'Unknown' }
        $alerts.Add("[$label] OFFLINE: $name is offline")
    }

    # --- TX retry rate ---
    if ($pct -and $null -ne $pct.txRetry) {
        $txRetry = [double]$pct.txRetry
        $txRound = [math]::Round($txRetry, 1)
        if ($txRetry -gt $TxRetryCriticalPct) {
            $alerts.Add("[$label] CRITICAL: WAN packet retry rate ${txRound}% (threshold: ${TxRetryCriticalPct}%)")
        }
        elseif ($txRetry -gt $TxRetryWarningPct) {
            $alerts.Add("[$label] WARNING: Elevated WAN packet retry rate ${txRound}% (threshold: ${TxRetryWarningPct}%)")
        }
    }

    # --- WAN uptime ---
    if ($pct -and $null -ne $pct.wanUptime) {
        $wanUptime = [double]$pct.wanUptime
        if ($wanUptime -lt $WanUptimeWarningPct) {
            $upRound = [math]::Round($wanUptime, 2)
            $alerts.Add("[$label] WARNING: WAN uptime ${upRound}% is below threshold (${WanUptimeWarningPct}%)")
        }
    }

    # --- Critical notifications ---
    if ($counts -and $null -ne $counts.criticalNotification -and [int]$counts.criticalNotification -gt 0) {
        $n = [int]$counts.criticalNotification
        $alerts.Add("[$label] ALERT: $n critical notification(s) on controller")
    }
}

#endregion

#region OUTPUT

if ($alerts.Count -gt 0) {
    Write-Host "UniFi Monitor: $($alerts.Count) issue(s) detected"
    Write-Host ''
    foreach ($a in $alerts) {
        Write-Host $a
    }
    exit 1
}
else {
    Write-Host 'UniFi Monitor: All sites healthy'
    exit 0
}

#endregion
