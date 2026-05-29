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
        3 — API error (UniFi unreachable or auth failure)
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
    Write-Host '<-Start Result->'
    Write-Host 'STATUS=CONFIGURATION ERROR: UnifiApiKey is not set. Add your API key to the script or configure the Datto global variable.'
    Write-Host '<-End Result->'
    exit 1
}

if (-not $SiteKeysRaw) {
    Write-Host '<-Start Result->'
    Write-Host 'STATUS=CONFIGURATION ERROR: Site variable UnifiSiteKeys is not set.'
    Write-Host '<-End Result->'
    exit 1
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

    try {
        $uriObj = New-Object System.Uri($uri, $true)
        $raw    = $wc.DownloadString($uriObj)
        return $raw | ConvertFrom-Json
    }
    catch [System.Net.WebException] {
        $status = $null
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        if ($status -eq 401 -or $status -eq 403) {
            throw "API authentication failed (HTTP $status). Check UnifiApiKey is correct."
        }
        elseif ($status -ge 500) {
            throw "UniFi API server error (HTTP $status) for endpoint '$Endpoint'."
        }
        else {
            throw "UniFi API unreachable at '$uri': $($_.Exception.Message)"
        }
    }
    catch {
        throw "Unexpected error calling '$uri': $($_.Exception.Message)"
    }
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
        catch {
            throw "Failed to retrieve devices for host '$HostId': $($_.Exception.Message)"
        }

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

function Get-AllSites {
    # Returns all sites from /v1/sites with pagination
    $all       = [System.Collections.Generic.List[object]]::new()
    $nextToken = $null
    do {
        $params = @{ pageSize = 200 }
        if ($nextToken) { $params['nextToken'] = $nextToken }
        $resp  = Invoke-UniFiRequest -Endpoint '/sites' -QueryParams $params
        $sites = if ($resp.data) { $resp.data } elseif ($resp -is [array]) { $resp } else { @() }
        foreach ($s in $sites) { $all.Add($s) }
        $nextToken = if ($resp.nextToken) { $resp.nextToken } else { $null }
    } while ($nextToken)
    return $all
}

function Resolve-Network {
    # Returns the site object matching hostId + optional networkId.
    # NetworkId is matched against site.id or site.meta.name (the internal slug).
    # Also returns the human-readable network name.
    param(
        [object[]]$AllSites,
        [string]$HostId,
        [string]$NetworkId
    )

    $hostSites = @($AllSites | Where-Object { $_.hostId -eq $HostId })

    if ($NetworkId) {
        $match = $hostSites | Where-Object {
            ($_.id -and $_.id -eq $NetworkId) -or
            ($_.meta -and $_.meta.name -and $_.meta.name -eq $NetworkId)
        } | Select-Object -First 1

        if ($match) {
            $networkName = if ($match.meta -and $match.meta.desc) { $match.meta.desc }
                           elseif ($match.meta -and $match.meta.name) { $match.meta.name }
                           else { $NetworkId }
            return @{ Site = $match; NetworkName = $networkName }
        }
        # NetworkId not matched — fall through to first site
        Write-Host "WARNING: NetworkId '$NetworkId' not matched for host '$HostId'. Using first available site."
    }

    $first = $hostSites | Select-Object -First 1
    $networkName = if ($first -and $first.meta -and $first.meta.desc) { $first.meta.desc }
                   elseif ($first -and $first.meta -and $first.meta.name) { $first.meta.name }
                   else { 'Unknown Network' }
    return @{ Site = $first; NetworkName = $networkName }
}

#endregion

#region ALERT EVALUATION

$alerts      = [System.Collections.Generic.List[string]]::new()
$apiErrors   = [System.Collections.Generic.List[string]]::new()
$entries     = Parse-SiteKeys -Raw $SiteKeysRaw

# Fetch all sites once — if this fails the whole run is aborted as we can't evaluate anything
$allSites = $null
try {
    $allSites = @(Get-AllSites)
}
catch {
    Write-Host '<-Start Result->'
    Write-Host "STATUS=API error — could not retrieve sites: $($_.Exception.Message)"
    Write-Host '<-End Result->'
    exit 1
}

foreach ($entry in $entries) {
    $hostId    = $entry.HostId
    $networkId = $entry.NetworkId

    try {
        # Resolve host name and network
        $hostName      = Get-HostName -HostId $hostId
        $networkResult = Resolve-Network -AllSites $allSites -HostId $hostId -NetworkId $networkId
        $site          = $networkResult.Site
        $networkName   = $networkResult.NetworkName

        # Build alert label: "HostName > NetworkName"
        $label = "$hostName > $networkName"

        # Get all devices for the host then filter to this network
        $allDevices = @(Get-Devices -HostId $hostId)

        # Filter devices to this specific network when a NetworkId was provided.
        # Devices carry a networkId or siteId field; fall back to all devices if neither is present.
        if ($networkId) {
            $networkDevices = @($allDevices | Where-Object {
                ($_.networkId -and $_.networkId -eq $networkId) -or
                ($_.siteId    -and $_.siteId    -eq $networkId)
            })
            $devices = if ($networkDevices.Count -gt 0) { $networkDevices } else { $allDevices }
        }
        else {
            $devices = $allDevices
        }

        # Get statistics from the matched site entry
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
    catch {
        $entryLabel = if ($networkId) { "$hostId|$networkId" } else { $hostId }
        $apiErrors.Add("[$entryLabel] API error: $($_.Exception.Message)")
    }
}

#endregion

#region OUTPUT

function Write-DattoResult {
    param([string]$Status)
    Write-Host '<-Start Result->'
    Write-Host "STATUS=$Status"
    Write-Host '<-End Result->'
}

if ($apiErrors.Count -gt 0 -and $alerts.Count -eq 0) {
    $msg = "API error(s) prevented evaluation: $($apiErrors -join ' | ')"
    Write-DattoResult -Status $msg
    exit 1
}

if ($alerts.Count -gt 0) {
    $summary = $alerts -join ' | '
    if ($apiErrors.Count -gt 0) {
        $summary += " | API errors: $($apiErrors -join ' | ')"
    }
    Write-DattoResult -Status $summary
    exit 1
}

Write-DattoResult -Status 'All sites healthy'
exit 0

#endregion
